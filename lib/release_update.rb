require "yaml"
require "open3"
require "net/http"
require "uri"
require "fileutils"

# Moves this checkout to a release (see bin/update). On a server, config/server.yml makes it the whole deploy:
# back up the database, update, restart, wait until the new version answers its health check, and go back to
# the previous release if it doesn't. Plain Ruby, so it runs before the bundle is installed.
class ReleaseUpdate
  class Failure < StandardError; end

  CONFIG_PATH = "config/server.yml"
  REQUIRED_SETTINGS = %w[restart health_url backup_directory].freeze
  DEFAULT_DATABASES = [ "storage/production.sqlite3" ].freeze
  DEFAULT_KEEP_BACKUPS = 10
  DEFAULT_HEALTH_TIMEOUT = 60
  HEALTH_INTERVAL = 2
  VERSION_HEADER = "X-App-Version"

  # Runs commands for real. Tests pass a fake with the same two methods.
  class Shell
    def initialize(out) = @out = out

    def run(env, *cmd)
      @out.puts "→ #{cmd.join(" ")}"
      system(env, *cmd)
    end

    def capture(*cmd)
      output, status = Open3.capture2e(*cmd)
      [ output.strip, status.success? ]
    end
  end

  def initialize(root:, wanted: nil, restart: true, out: $stdout, shell: Shell.new(out), http: nil, sleeper: method(:sleep), clock: -> { Time.now })
    @root, @wanted, @restart, @out, @shell, @sleeper, @clock = root, wanted.to_s.strip, restart, out, shell, sleeper, clock
    @http = http || method(:http_get)
  end

  def call
    Dir.chdir(@root) do
      config = load_config
      env = config ? environment(config) : {}
      check_clean!
      tag = resolve_tag
      previous = current_tag
      backup = backup!(config, previous) if config

      begin
        install!(tag, env)
        if config && @restart
          restart!(config)
          healthy!(config, tag)
        end
      rescue Failure => error
        raise unless config && @restart && previous && previous != tag

        say "✗ #{error.message}"
        say "↩ Going back to #{previous}"
        install!(previous, env, migrate: false)
        restart!(config)
        healthy!(config, previous, exact: false)
        raise Failure, "Updating to #{tag} failed, so #{previous} is running again. Any migrations from #{tag} that ran " \
                       "stay applied (they're additive); the database from before the update is in #{backup}."
      end

      say done_message(tag, previous, config, backup)
      tag
    end
  end

  private
    def say(message) = @out.puts(message)

    def capture!(*cmd)
      output, ok = @shell.capture(*cmd)
      raise Failure, "`#{cmd.join(" ")}` failed:\n#{output}" unless ok

      output
    end

    def run!(env, *cmd)
      raise Failure, "`#{cmd.join(" ")}` failed." unless @shell.run(env, *cmd)
    end

    def load_config
      return unless File.file?(CONFIG_PATH)

      config = YAML.safe_load_file(CONFIG_PATH) || {}
      raise Failure, "#{CONFIG_PATH} must be a list of settings (see config/server.example.yml)." unless config.is_a?(Hash)

      missing = REQUIRED_SETTINGS.reject { |key| config[key].to_s.strip != "" }
      raise Failure, "#{CONFIG_PATH} is missing #{missing.join(", ")} (see config/server.example.yml)." if missing.any?

      config
    end

    # The app's own environment, e.g. the file systemd's EnvironmentFile= points at, so every step runs the way
    # the app does. KEY=VALUE lines; blank lines, comments and `export` are allowed.
    def environment(config)
      env = {}
      if (file = config["environment_file"])
        raise Failure, "The environment file #{file} doesn't exist." unless File.file?(file)

        File.foreach(file) do |line|
          line = line.strip.delete_prefix("export ").strip
          next if line.empty? || line.start_with?("#") || !line.include?("=")

          key, value = line.split("=", 2)
          env[key.strip] = value.strip.sub(/\A(["'])(.*)\1\z/, '\2')
        end
      end
      env.merge!(config["environment"].to_h.transform_values(&:to_s))
      unless (env["RAILS_ENV"] || ENV["RAILS_ENV"]).to_s == "production"
        raise Failure, "A server update needs RAILS_ENV=production, in the environment file or `environment:` of #{CONFIG_PATH}."
      end

      env
    end

    def check_clean!
      changes = capture!("git", "status", "--porcelain", "--untracked-files=no")
      raise Failure, "There are uncommitted changes to tracked files; resolve them first:\n#{changes}" unless changes.empty?
    end

    def resolve_tag
      capture!("git", "fetch", "--quiet", "--tags", "--force", "origin")
      tags = capture!("git", "tag", "--list", "v[0-9]*", "--sort=-v:refname").lines.map(&:strip)
      raise Failure, "No releases yet." if tags.empty?
      return tags.first if @wanted.empty? || @wanted == "latest"

      tag = @wanted.start_with?("v") ? @wanted : "v#{@wanted}"
      raise Failure, "There's no release #{tag}. Available: #{tags.first(5).join(", ")}" unless tags.include?(tag)

      tag
    end

    def current_tag
      output, ok = @shell.capture("git", "describe", "--tags", "--exact-match", "--match", "v[0-9]*", "HEAD")
      ok ? output : nil
    end

    # sqlite3's .backup copies a consistent snapshot while the app keeps running.
    def backup!(config, previous)
      root = config["backup_directory"]
      dir = File.join(root, "#{@clock.call.strftime("%Y%m%d-%H%M%S")}-#{previous || "untagged"}")
      FileUtils.mkdir_p(dir)
      Array(config["databases"] || DEFAULT_DATABASES).each do |database|
        source = File.expand_path(database)
        raise Failure, "The database #{source} doesn't exist; check `databases:` in #{CONFIG_PATH}." unless File.file?(source)

        target = File.join(dir, File.basename(source))
        unless @shell.run({}, "sqlite3", source, ".backup '#{target.gsub("'", "''")}'")
          raise Failure, "Backing up #{source} failed. Is the sqlite3 command installed?"
        end
      end
      prune_backups(root, Integer(config.fetch("keep_backups", DEFAULT_KEEP_BACKUPS)))
      dir
    end

    def prune_backups(root, keep)
      sets = Dir.children(root).select { |name| name.match?(/\A\d{8}-\d{6}-/) && File.directory?(File.join(root, name)) }.sort
      sets.first([ sets.size - keep, 0 ].max).each { |name| FileUtils.rm_rf(File.join(root, name)) }
    end

    def install!(tag, env, migrate: true)
      run!({}, "git", "checkout", "--quiet", tag)
      run!(env, "bundle", "install", "--quiet")
      run!(env, "bin/rails", "db:migrate") if migrate
      run!(env, "bin/rails", "assets:precompile") if (env["RAILS_ENV"] || ENV["RAILS_ENV"]) == "production"
    end

    def restart!(config)
      raise Failure, "The restart command failed: #{config["restart"]}" unless @shell.run({}, "sh", "-c", config["restart"])
    end

    # Healthy means /up answers 200 and says it's running the expected version, not the one before the restart.
    # Going back, exact: false also accepts a release from before /up said its version (v0.2.1 and older).
    def healthy!(config, tag, exact: true)
      version = tag.delete_prefix("v")
      deadline = @clock.call + Integer(config.fetch("health_timeout", DEFAULT_HEALTH_TIMEOUT))
      last = nil
      loop do
        status, served = @http.call(config["health_url"])
        return say("✓ #{config["health_url"]} answers with #{version}") if status == 200 && (served == version || (!exact && served.nil?))

        last = status ? "HTTP #{status}#{", version #{served}" if served}" : "no answer"
        break if @clock.call >= deadline

        @sleeper.call(HEALTH_INTERVAL)
      end
      raise Failure, "#{config["health_url"]} didn't answer with #{version} within #{config.fetch("health_timeout", DEFAULT_HEALTH_TIMEOUT)}s (last: #{last})."
    end

    def http_get(url)
      uri = URI(url)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 5) do |http|
        http.get(uri.request_uri)
      end
      [ response.code.to_i, response[VERSION_HEADER] ]
    rescue StandardError
      [ nil, nil ]
    end

    def done_message(tag, previous, config, backup)
      lines = [ "✓ Now on #{tag} (was #{previous || "untagged"})." ]
      if config.nil?
        lines << "  Restart the app to serve it. On a server, #{CONFIG_PATH} makes bin/update restart and check it (see AGENTS.md)."
      elsif !@restart
        lines << "  Not restarted (--no-restart). Database backup: #{backup}"
      else
        lines << "  Restarted and healthy. Database backup: #{backup}"
      end
      lines.join("\n")
    end
end
