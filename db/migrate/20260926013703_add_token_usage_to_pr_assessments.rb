class AddTokenUsageToPrAssessments < ActiveRecord::Migration[8.1]
  def change
    add_column :pr_assessments, :input_tokens, :integer, null: false, default: 0
    add_column :pr_assessments, :output_tokens, :integer, null: false, default: 0
    add_index :pr_assessments, :created_at
    add_index :pr_assessments, [ :user_id, :created_at ]
  end
end
