class CreatePinnedRepositories < ActiveRecord::Migration[8.1]
  def change
    create_table :pinned_repositories do |t|
      t.references :user, null: false, foreign_key: true
      t.string :full_name, null: false

      t.timestamps
    end
    add_index :pinned_repositories, [ :user_id, :full_name ], unique: true
  end
end
