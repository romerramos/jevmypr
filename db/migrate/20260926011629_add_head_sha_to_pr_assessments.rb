class AddHeadShaToPrAssessments < ActiveRecord::Migration[8.1]
  def change
    add_column :pr_assessments, :head_sha, :string
  end
end
