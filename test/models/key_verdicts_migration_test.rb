require "test_helper"
require Rails.root.join("db/migrate/20261011160000_key_verdicts_without_repository")

class KeyVerdictsMigrationTest < ActiveSupport::TestCase
  MIGRATION = "20261011160000_key_verdicts_without_repository.rb"

  class MigrationDatabase < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    MigrationDatabase.establish_connection(adapter: "sqlite3", database: ":memory:")
    @connection = MigrationDatabase.connection
    Dir[Rails.root.join("db/migrate/*.rb")].sort.each do |path|
      break if File.basename(path) == MIGRATION

      migrate(path, :up)
    end
  end

  teardown { MigrationDatabase.remove_connection }

  test "keeps existing verdicts as web verdicts and moves API reservations to their own key" do
    insert(:repositories, id: 1, github_id: 101, full_name: "acme/web")
    insert(:pr_assessments, id: 11, repository_id: 1, repo_full_name: "acme/web", pr_number: 7, pr_title: "Fix",
           pr_url: "https://github.com/acme/web/pull/7", head_sha: "sha-7", choice: "no")
    insert(:jev_requests, id: 21, repository_id: 1, pr_number: 7, head_sha: "sha-7", state: "succeeded")
    insert(:jev_requests, id: 22, source: "api", head_sha: "diff-hash", state: "succeeded", ip_digest: "ip")

    migrate(MIGRATION, :up)

    assert_equal [ "web", nil, nil, nil ],
                 @connection.select_one("SELECT source, diff_sha256, token, expires_at FROM pr_assessments WHERE id = 11").values
    requests = @connection.select_rows("SELECT id, head_sha, diff_sha256 FROM jev_requests ORDER BY id")
    assert_equal [ [ 21, "sha-7", nil ], [ 22, nil, "diff-hash" ] ], requests

    insert(:pr_assessments, id: 12, source: "api", diff_sha256: "diff-hash", token: "t" * 24, expires_at: "2026-11-10 00:00:00",
           pr_title: "Sent diff", choice: "yes")
    assert_raises(ActiveRecord::StatementInvalid) { insert(:pr_assessments, id: 13, pr_title: "Web without a PR", choice: "no") }
    assert_raises(ActiveRecord::StatementInvalid) do
      insert(:pr_assessments, id: 14, source: "api", repository_id: 1, diff_sha256: "x", token: "u" * 24,
             expires_at: "2026-11-10 00:00:00", pr_title: "API with a repository", choice: "no")
    end

    migrate(MIGRATION, :down)

    assert_equal [ 11 ], @connection.select_values("SELECT id FROM pr_assessments")
    assert_equal [ [ 21, "sha-7" ], [ 22, "diff-hash" ] ], @connection.select_rows("SELECT id, head_sha FROM jev_requests ORDER BY id")
    assert_not @connection.column_exists?(:pr_assessments, :token)
  end

  private
    def migrate(file, direction)
      path = file.include?("/") ? file : Rails.root.join("db/migrate", file).to_s
      require path
      migration = File.basename(path, ".rb").sub(/\A\d+_/, "").camelize.constantize.new
      migration.suppress_messages { migration.exec_migration(@connection, direction) }
    end

    def insert(table, **values)
      now = "2026-10-11 12:00:00"
      values = values.merge(created_at: now, updated_at: now)
      @connection.execute("INSERT INTO #{table} (#{values.keys.join(", ")}) VALUES (#{values.values.map { |v| @connection.quote(v) }.join(", ")})")
    end
end
