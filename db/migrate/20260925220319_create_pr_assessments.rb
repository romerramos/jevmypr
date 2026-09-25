class CreatePrAssessments < ActiveRecord::Migration[8.1]
  def change
    create_table :pr_assessments do |t|
      t.references :user, null: false, foreign_key: true
      t.string :repo_full_name, null: false
      t.integer :pr_number, null: false
      t.string :pr_title, null: false
      t.string :pr_url, null: false
      t.string :pr_author
      t.integer :additions, null: false, default: 0
      t.integer :deletions, null: false, default: 0
      t.integer :changed_files, null: false, default: 0
      t.json :files, null: false, default: []
      t.string :choice, null: false
      t.json :probabilities, null: false, default: {}
      t.float :confidence
      t.string :jev_model
      t.boolean :diff_truncated, null: false, default: false

      t.timestamps
    end
    add_index :pr_assessments, [ :user_id, :repo_full_name, :pr_number ]
  end
end
