class CreateOversizedPullRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :oversized_pull_requests do |t|
      t.references :user, null: false, foreign_key: true
      t.string :repo_full_name, null: false
      t.integer :pr_number, null: false
      t.string :head_sha

      t.timestamps
    end
    add_index :oversized_pull_requests, [ :user_id, :repo_full_name, :pr_number ], unique: true
  end
end
