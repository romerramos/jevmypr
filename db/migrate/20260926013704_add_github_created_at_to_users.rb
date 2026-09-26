class AddGithubCreatedAtToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :github_created_at, :datetime
  end
end
