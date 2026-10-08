require "test_helper"
require Rails.root.join("db/migrate/20261005070000_share_repository_verdicts")

class SharedVerdictsMigrationTest < ActiveSupport::TestCase
  class MigrationDatabase < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    MigrationDatabase.establish_connection(adapter: "sqlite3", database: ":memory:")
    @connection = MigrationDatabase.connection
    Dir[Rails.root.join("db/migrate/*.rb")].sort.each do |path|
      break if File.basename(path) == "20261005070000_share_repository_verdicts.rb"

      require path
      migration = File.basename(path, ".rb").sub(/\A\d+_/, "").camelize.constantize.new
      migration.suppress_messages { migration.exec_migration(@connection, :up) }
    end
  end

  teardown do
    MigrationDatabase.remove_connection
  end

  test "upgrade preserves private history, original votes and spend without guessing repository IDs" do
    insert(:users, id: 1, github_uid: "old-owner", login: "old-owner")
    insert(:users, id: 2, github_uid: "old-teammate", login: "old-teammate")
    insert(:pr_assessments, id: 11, user_id: 1, repo_full_name: "acme/web", pr_number: 7,
      pr_title: "O'Hara <script>old history</script>", pr_url: "https://github.com/acme/web/pull/7",
      choice: "no", head_sha: "same-head", files: [ { filename: "a' file.rb", choice: "yes" } ].to_json,
      probabilities: { "no" => 0.9, "yes" => 0.1 }.to_json, input_tokens: 2000, output_tokens: 3,
      feedback_choice: "yes", feedback_reason: "Original owner's private reason <>&",
      feedback_at: "2026-10-02 08:00:00")
    insert(:pr_assessments, id: 22, user_id: 2, repo_full_name: "acme/web", pr_number: 7,
      pr_title: "Same name and SHA, different owner", pr_url: "https://github.com/acme/web/pull/7",
      choice: "yes", head_sha: "same-head", input_tokens: 17, output_tokens: 5,
      feedback_choice: "llm_enough", feedback_at: nil)
    insert(:pr_assessments, id: 33, user_id: 1, repo_full_name: "acme/renamed", pr_number: 9,
      pr_title: "Unknown head", pr_url: "https://github.com/acme/renamed/pull/9", choice: "yes")
    insert(:oversized_pull_requests, id: 44, user_id: 1, repo_full_name: "acme/web", pr_number: 8)
    originals = @connection.select_all("SELECT * FROM pr_assessments ORDER BY id").to_a
    marker = @connection.select_one("SELECT * FROM oversized_pull_requests")

    migration = ShareRepositoryVerdicts.new
    migration.suppress_messages { migration.exec_migration(@connection, :up) }

    assert_equal 0, @connection.select_value("SELECT COUNT(*) FROM repositories")
    snapshots = @connection.select_all("SELECT * FROM pr_assessments ORDER BY id").to_a
    assert_equal originals.map { |row| row.except("feedback_choice", "feedback_reason", "feedback_at") },
      snapshots.map { |row| row.except("repository_id", "jev_request_id") }
    snapshots.each do |row|
      assert_nil row["repository_id"]
      assert_nil row["jev_request_id"]
    end
    votes = @connection.select_all("SELECT * FROM feedbacks ORDER BY pr_assessment_id").to_a
    assert_equal [ 11, 22 ], votes.map { |row| row["pr_assessment_id"] }
    assert_equal [ 1, 2 ], votes.map { |row| row["user_id"] }
    assert_equal [ "yes", "llm_enough" ], votes.map { |row| row["choice"] }
    assert_equal "Original owner's private reason <>&", votes.first["reason"]
    assert_equal originals.first["feedback_at"], votes.first["voted_at"]
    assert_equal originals.second["created_at"], votes.second["voted_at"]
    assert_equal originals.first["updated_at"], votes.first["updated_at"]
    usage = @connection.select_all("SELECT * FROM jev_requests ORDER BY id").to_a
    assert_equal [ 1, 2, 1 ], usage.map { |row| row["user_id"] }
    assert_equal [ 2000, 17, 0 ], usage.map { |row| row["input_tokens"] }
    assert_equal [ 3, 5, 0 ], usage.map { |row| row["output_tokens"] }
    assert_equal originals.map { |row| row["created_at"] }, usage.map { |row| row["sent_at"] }
    assert_equal [ nil, nil, nil ], usage.map { |row| row["repository_id"] }
    assert_equal marker, @connection.select_one("SELECT * FROM oversized_pull_requests").except("repository_id")
    assert_nil @connection.select_value("SELECT repository_id FROM oversized_pull_requests")
    assert_not_requested :any, %r{\Ahttps://(?:api\.github\.com|api\.typesafe\.ai)/}

    assert_raises(ActiveRecord::IrreversibleMigration) { migration.exec_migration(@connection, :down) }
    assert_equal snapshots, @connection.select_all("SELECT * FROM pr_assessments ORDER BY id").to_a
    assert_equal votes, @connection.select_all("SELECT * FROM feedbacks ORDER BY pr_assessment_id").to_a
  end

  private
    def insert(table, **attributes)
      attributes = { created_at: "2026-09-29 10:00:00", updated_at: "2026-10-02 09:00:00" }.merge(attributes)
      columns = attributes.keys.map { |name| @connection.quote_column_name(name) }.join(", ")
      values = attributes.values.map { |value| @connection.quote(value) }.join(", ")
      @connection.execute("INSERT INTO #{@connection.quote_table_name(table)} (#{columns}) VALUES (#{values})")
    end
end
