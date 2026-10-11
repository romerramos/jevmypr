class ShareRepositoryVerdicts < ActiveRecord::Migration[8.1]
  def up
    create_table :repositories do |t|
      t.integer :github_id, null: false
      t.string :full_name, null: false
      t.timestamps
    end
    add_index :repositories, :github_id, unique: true

    # Also a short-lived reservation for an ordinary analysis of a particular commit.
    # No database transaction is held while GitHub or Jev is being called.
    create_table :jev_requests do |t|
      t.references :repository, foreign_key: true
      t.references :user, foreign_key: true
      t.integer :pr_number
      t.string :head_sha
      t.boolean :fresh, null: false, default: false
      t.string :state, null: false, default: "pending"
      t.datetime :sent_at
      t.integer :input_tokens, null: false, default: 0
      t.integer :output_tokens, null: false, default: 0
      t.timestamps
    end
    add_index :jev_requests, [ :repository_id, :pr_number, :head_sha ], unique: true,
      where: "state = 'pending' AND fresh = 0", name: "one_pending_ordinary_analysis"
    add_index :jev_requests, [ :user_id, :created_at ]
    add_index :jev_requests, :created_at

    add_reference :pr_assessments, :repository, foreign_key: true
    add_reference :pr_assessments, :jev_request, foreign_key: true, index: { unique: true }
    change_column_null :pr_assessments, :user_id, true
    add_index :pr_assessments, [ :repository_id, :pr_number, :head_sha ]

    create_table :feedbacks do |t|
      t.references :pr_assessment, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :choice, null: false
      t.text :reason
      t.datetime :voted_at, null: false
      t.timestamps
    end
    add_index :feedbacks, [ :user_id, :pr_assessment_id ], unique: true

    # Existing snapshots have no trustworthy GitHub repository ID. Keep them private and
    # unbound; do not guess an identity from their names or contact GitHub in a migration.
    execute <<~SQL
      INSERT INTO feedbacks (pr_assessment_id, user_id, choice, reason, voted_at, created_at, updated_at)
      SELECT id, user_id, feedback_choice, feedback_reason, COALESCE(feedback_at, created_at), created_at, updated_at
      FROM pr_assessments WHERE feedback_choice IS NOT NULL
    SQL
    execute <<~SQL
      INSERT INTO jev_requests (user_id, state, sent_at, input_tokens, output_tokens, created_at, updated_at)
      SELECT user_id, 'succeeded', created_at, input_tokens, output_tokens, created_at, updated_at
      FROM pr_assessments
    SQL
    remove_column :pr_assessments, :feedback_choice
    remove_column :pr_assessments, :feedback_reason
    remove_column :pr_assessments, :feedback_at

    add_reference :oversized_pull_requests, :repository, foreign_key: true
    change_column_null :oversized_pull_requests, :user_id, true
    add_index :oversized_pull_requests, [ :repository_id, :pr_number, :head_sha ], unique: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Shared verdicts and personal votes cannot be represented by the old schema. Restore a pre-upgrade backup instead."
  end
end
