class AddFeedbackToPrAssessments < ActiveRecord::Migration[8.1]
  def change
    add_column :pr_assessments, :feedback_choice, :string
    add_column :pr_assessments, :feedback_reason, :text
    add_column :pr_assessments, :feedback_at, :datetime
  end
end
