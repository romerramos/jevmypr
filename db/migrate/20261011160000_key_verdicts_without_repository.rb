# Verdicts for diffs sent to the open API have no GitHub repository, pull request or requester. They're keyed
# by the diff's hash, reached through an unguessable token and deleted when they expire.
class KeyVerdictsWithoutRepository < ActiveRecord::Migration[8.1]
  def up
    add_column :pr_assessments, :source, :string, null: false, default: "web"
    add_column :pr_assessments, :diff_sha256, :string
    add_column :pr_assessments, :token, :string
    add_column :pr_assessments, :expires_at, :datetime
    change_column_null :pr_assessments, :repo_full_name, true
    change_column_null :pr_assessments, :pr_number, true
    change_column_null :pr_assessments, :pr_url, true
    add_index :pr_assessments, :token, unique: true
    add_index :pr_assessments, [ :diff_sha256, :created_at ]
    add_index :pr_assessments, :expires_at
    add_check_constraint :pr_assessments,
      "source = 'api' OR (repo_full_name IS NOT NULL AND pr_number IS NOT NULL AND pr_url IS NOT NULL)",
      name: "web_verdicts_have_a_pull_request"
    add_check_constraint :pr_assessments,
      "source <> 'api' OR (repository_id IS NULL AND user_id IS NULL AND diff_sha256 IS NOT NULL AND token IS NOT NULL AND expires_at IS NOT NULL)",
      name: "api_verdicts_have_no_owner"

    # API reservations kept the diff's hash in head_sha; give it its own column and one pending request per diff.
    add_column :jev_requests, :diff_sha256, :string
    execute "UPDATE jev_requests SET diff_sha256 = head_sha, head_sha = NULL WHERE source = 'api'"
    add_index :jev_requests, :diff_sha256, unique: true, name: "one_pending_ordinary_diff_analysis",
      where: "state = 'pending' AND fresh = 0 AND diff_sha256 IS NOT NULL"
  end

  def down
    execute "DELETE FROM pr_assessments WHERE source = 'api'"
    remove_index :jev_requests, name: "one_pending_ordinary_diff_analysis"
    execute "UPDATE jev_requests SET head_sha = diff_sha256 WHERE source = 'api'"
    remove_column :jev_requests, :diff_sha256

    remove_check_constraint :pr_assessments, name: "api_verdicts_have_no_owner"
    remove_check_constraint :pr_assessments, name: "web_verdicts_have_a_pull_request"
    remove_index :pr_assessments, :expires_at
    remove_index :pr_assessments, [ :diff_sha256, :created_at ]
    remove_index :pr_assessments, :token
    change_column_null :pr_assessments, :pr_url, false
    change_column_null :pr_assessments, :pr_number, false
    change_column_null :pr_assessments, :repo_full_name, false
    remove_column :pr_assessments, :expires_at
    remove_column :pr_assessments, :token
    remove_column :pr_assessments, :diff_sha256
    remove_column :pr_assessments, :source
  end
end
