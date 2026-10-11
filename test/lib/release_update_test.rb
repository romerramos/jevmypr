require "test_helper"

class ReleaseUpdateTest < ActiveSupport::TestCase
  # Records commands and answers git queries; `fail` makes the commands it matches fail.
  class FakeShell
    attr_reader :runs

    def initialize(tags: %w[v0.2.1 v0.2.0], current: "v0.2.0", dirty: "", fail: nil)
      @tags, @current, @dirty, @fail = tags, current, dirty, fail
      @runs = []
    end

    def run(env, *cmd)
      @runs << [ env, cmd ]
      !@fail&.match?(cmd.join(" "))
    end

    def capture(*cmd)
      case cmd.join(" ")
      when /\Agit status/ then [ @dirty, true ]
      when /\Agit fetch/ then [ "", true ]
      when /\Agit tag --list/ then [ @tags.join("\n"), true ]
      when /\Agit describe/ then @current ? [ @current, true ] : [ "fatal: no tag", false ]
      else raise "unexpected #{cmd.inspect}"
      end
    end

    def commands = runs.map { |_, cmd| cmd.join(" ") }
  end

  setup do
    @root = Dir.mktmpdir
    @backups = File.join(@root, "backups")
    FileUtils.mkdir_p(File.join(@root, "config"))
    FileUtils.mkdir_p(File.join(@root, "storage"))
    File.write(File.join(@root, "storage/production.sqlite3"), "db")
    File.write(File.join(@root, "app.env"), <<~ENV)
      # the app's environment
      export RAILS_ENV=production
      SECRET_KEY_BASE="abc=def"

      DATABASE_DIR='/srv/shared'
    ENV
    @out = StringIO.new
    @now = Time.new(2026, 10, 11, 15, 0, 0)
    # Each health poll sleeps; the fake clock moves on by that much.
    @sleeper = ->(seconds) { @now += seconds }
  end

  teardown { FileUtils.rm_rf(@root) }

  def write_config(**settings)
    config = { "environment_file" => File.join(@root, "app.env"), "restart" => "sudo systemctl restart jevmypr",
               "health_url" => "http://127.0.0.1:3000/up", "health_timeout" => 10, "backup_directory" => @backups }
    File.write(File.join(@root, "config/server.yml"), config.merge(settings.transform_keys(&:to_s)).compact.to_yaml)
  end

  def update(shell, wanted: "v0.2.1", restart: true, health: [ [ 200, "0.2.1" ] ])
    answers = health.dup
    http = ->(_url) { answers.size > 1 ? answers.shift : answers.first }
    ReleaseUpdate.new(root: @root, wanted: wanted, restart: restart, out: @out, shell: shell, http: http,
                      sleeper: @sleeper, clock: -> { @now }).call
  end

  test "without server settings it only updates the checkout, as before" do
    shell = FakeShell.new

    assert_equal "v0.2.1", update(shell)

    assert_equal [ "git checkout --quiet v0.2.1", "bundle install --quiet", "bin/rails db:migrate" ], shell.commands
    assert_match "Restart the app to serve it", @out.string
  end

  test "on a server it backs up, updates with the app's environment, restarts and waits for the new version" do
    write_config
    shell = FakeShell.new

    update(shell, health: [ [ nil, nil ], [ 200, "0.2.0" ], [ 200, "0.2.1" ] ])

    backup = File.join(@backups, "20261011-150000-v0.2.0")
    assert_equal [ "sqlite3 #{@root}/storage/production.sqlite3 .backup '#{backup}/production.sqlite3'",
                   "git checkout --quiet v0.2.1", "bundle install --quiet", "bin/rails db:migrate", "bin/rails assets:precompile",
                   "sh -c sudo systemctl restart jevmypr" ], shell.commands
    env = shell.runs.find { |_, cmd| cmd == [ "bin/rails", "db:migrate" ] }.first
    assert_equal({ "RAILS_ENV" => "production", "SECRET_KEY_BASE" => "abc=def", "DATABASE_DIR" => "/srv/shared" }, env)
    assert File.directory?(backup)
    assert_match "Restarted and healthy. Database backup: #{backup}", @out.string
  end

  test "goes back to the previous release when the new one doesn't come up" do
    write_config
    shell = FakeShell.new

    error = assert_raises(ReleaseUpdate::Failure) { update(shell, health: [ [ 500, nil ], [ 500, nil ], [ 200, "0.2.0" ] ]) }

    # It stops polling once the timeout has passed, then reinstalls v0.2.0 without migrating.
    assert_equal [ "git checkout --quiet v0.2.0", "bundle install --quiet", "bin/rails assets:precompile",
                   "sh -c sudo systemctl restart jevmypr" ], shell.commands.last(4)
    assert_match "Updating to v0.2.1 failed, so v0.2.0 is running again", error.message
    assert_match File.join(@backups, "20261011-"), error.message
    assert_match "last: HTTP 200, version 0.2.0", @out.string # the old release was still answering
  end

  test "going back accepts a release from before /up said its version" do
    write_config
    shell = FakeShell.new(current: "v0.2.1", tags: %w[v0.2.2 v0.2.1])

    error = assert_raises(ReleaseUpdate::Failure) { update(shell, wanted: "v0.2.2", health: [ [ 200, nil ] ]) }

    assert_match "Updating to v0.2.2 failed, so v0.2.1 is running again", error.message
    assert_match "(last: HTTP 200)", @out.string
  end

  test "a failed step after the checkout also goes back" do
    write_config
    shell = FakeShell.new(fail: /db:migrate/)

    error = assert_raises(ReleaseUpdate::Failure) { update(shell, health: [ [ 200, "0.2.0" ] ]) }

    assert_match "`bin/rails db:migrate` failed", @out.string
    assert_includes shell.commands, "git checkout --quiet v0.2.0"
    assert_match "v0.2.0 is running again", error.message
  end

  test "can't go back from a checkout that wasn't on a release" do
    write_config
    shell = FakeShell.new(current: nil)

    error = assert_raises(ReleaseUpdate::Failure) { update(shell, health: [ [ 500, nil ] ]) }

    assert_match "didn't answer with 0.2.1", error.message
    assert_not_includes shell.commands, "git checkout --quiet v0.2.0"
    assert File.directory?(File.join(@backups, "20261011-150000-untagged"))
  end

  test "--no-restart updates but leaves the restart for later" do
    write_config
    shell = FakeShell.new

    update(shell, restart: false)

    assert_not shell.commands.any? { |command| command.start_with?("sh -c") }
    assert_match "Not restarted (--no-restart)", @out.string
  end

  test "keeps the newest backup sets" do
    write_config(keep_backups: 2)
    %w[20261001-100000-v0.1.0 20261002-100000-v0.1.1 20261003-100000-v0.1.2 notes].each { |name| FileUtils.mkdir_p(File.join(@backups, name)) }

    update(FakeShell.new)

    assert_equal %w[20261003-100000-v0.1.2 20261011-150000-v0.2.0 notes], Dir.children(@backups).sort
  end

  test "refuses to start with incomplete settings, a non-production environment or a missing database" do
    File.write(File.join(@root, "config/server.yml"), { "restart" => "true" }.to_yaml)
    assert_match "missing health_url, backup_directory", assert_raises(ReleaseUpdate::Failure) { update(FakeShell.new) }.message

    write_config(environment_file: nil, environment: { "RAILS_ENV" => "development" })
    assert_match "needs RAILS_ENV=production", assert_raises(ReleaseUpdate::Failure) { update(FakeShell.new) }.message

    write_config(databases: [ "storage/missing.sqlite3" ])
    assert_match "missing.sqlite3 doesn't exist", assert_raises(ReleaseUpdate::Failure) { update(FakeShell.new) }.message
  end

  test "refuses unknown releases and uncommitted changes, before changing anything" do
    shell = FakeShell.new
    assert_match "There's no release v9.9.9", assert_raises(ReleaseUpdate::Failure) { update(shell, wanted: "9.9.9") }.message

    dirty = FakeShell.new(dirty: " M Gemfile")
    assert_match "uncommitted changes", assert_raises(ReleaseUpdate::Failure) { update(dirty) }.message
    assert_empty shell.runs + dirty.runs
  end

  test "latest is the newest release" do
    shell = FakeShell.new(tags: %w[v0.10.0 v0.9.0])

    assert_equal "v0.10.0", update(shell, wanted: "latest")
  end
end
