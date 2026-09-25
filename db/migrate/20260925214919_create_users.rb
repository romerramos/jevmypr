class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :github_uid, null: false
      t.string :login, null: false
      t.string :name
      t.string :avatar_url
      t.text :github_token

      t.timestamps
    end
    add_index :users, :github_uid, unique: true
  end
end
