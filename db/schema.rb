# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_10_05_070000) do
  create_table "feedbacks", force: :cascade do |t|
    t.integer "pr_assessment_id", null: false
    t.integer "user_id", null: false
    t.string "choice", null: false
    t.text "reason"
    t.datetime "voted_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["pr_assessment_id"], name: "index_feedbacks_on_pr_assessment_id"
    t.index ["user_id", "pr_assessment_id"], name: "index_feedbacks_on_user_id_and_pr_assessment_id", unique: true
    t.index ["user_id"], name: "index_feedbacks_on_user_id"
  end

  create_table "jev_requests", force: :cascade do |t|
    t.integer "repository_id"
    t.integer "user_id"
    t.integer "pr_number"
    t.string "head_sha"
    t.boolean "fresh", default: false, null: false
    t.string "state", default: "pending", null: false
    t.datetime "sent_at"
    t.integer "input_tokens", default: 0, null: false
    t.integer "output_tokens", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_jev_requests_on_created_at"
    t.index ["repository_id", "pr_number", "head_sha"], name: "one_pending_ordinary_analysis", unique: true, where: "state = 'pending' AND fresh = 0"
    t.index ["repository_id"], name: "index_jev_requests_on_repository_id"
    t.index ["user_id", "created_at"], name: "index_jev_requests_on_user_id_and_created_at"
    t.index ["user_id"], name: "index_jev_requests_on_user_id"
  end

  create_table "oversized_pull_requests", force: :cascade do |t|
    t.integer "user_id"
    t.string "repo_full_name", null: false
    t.integer "pr_number", null: false
    t.string "head_sha"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "repository_id"
    t.index ["repository_id", "pr_number", "head_sha"], name: "idx_on_repository_id_pr_number_head_sha_845b4a0443", unique: true
    t.index ["repository_id"], name: "index_oversized_pull_requests_on_repository_id"
    t.index ["user_id", "repo_full_name", "pr_number"], name: "idx_on_user_id_repo_full_name_pr_number_49d7c0e14b", unique: true
    t.index ["user_id"], name: "index_oversized_pull_requests_on_user_id"
  end

  create_table "pinned_repositories", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "full_name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id", "full_name"], name: "index_pinned_repositories_on_user_id_and_full_name", unique: true
    t.index ["user_id"], name: "index_pinned_repositories_on_user_id"
  end

  create_table "pr_assessments", force: :cascade do |t|
    t.integer "user_id"
    t.string "repo_full_name", null: false
    t.integer "pr_number", null: false
    t.string "pr_title", null: false
    t.string "pr_url", null: false
    t.string "pr_author"
    t.integer "additions", default: 0, null: false
    t.integer "deletions", default: 0, null: false
    t.integer "changed_files", default: 0, null: false
    t.json "files", default: [], null: false
    t.string "choice", null: false
    t.json "probabilities", default: {}, null: false
    t.float "confidence"
    t.string "jev_model"
    t.boolean "diff_truncated", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "head_sha"
    t.integer "input_tokens", default: 0, null: false
    t.integer "output_tokens", default: 0, null: false
    t.integer "repository_id"
    t.integer "jev_request_id"
    t.index ["created_at"], name: "index_pr_assessments_on_created_at"
    t.index ["jev_request_id"], name: "index_pr_assessments_on_jev_request_id", unique: true
    t.index ["repository_id", "pr_number", "head_sha"], name: "idx_on_repository_id_pr_number_head_sha_308ac37bf4"
    t.index ["repository_id"], name: "index_pr_assessments_on_repository_id"
    t.index ["user_id", "created_at"], name: "index_pr_assessments_on_user_id_and_created_at"
    t.index ["user_id", "repo_full_name", "pr_number"], name: "idx_on_user_id_repo_full_name_pr_number_7bb4f04b72"
    t.index ["user_id"], name: "index_pr_assessments_on_user_id"
  end

  create_table "repositories", force: :cascade do |t|
    t.integer "github_id", null: false
    t.string "full_name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["github_id"], name: "index_repositories_on_github_id", unique: true
  end

  create_table "sessions", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "ip_address"
    t.string "user_agent"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "github_uid", null: false
    t.string "login", null: false
    t.string "name"
    t.string "avatar_url"
    t.text "github_token"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "github_created_at"
    t.index ["github_uid"], name: "index_users_on_github_uid", unique: true
  end

  add_foreign_key "feedbacks", "pr_assessments"
  add_foreign_key "feedbacks", "users"
  add_foreign_key "jev_requests", "repositories"
  add_foreign_key "jev_requests", "users"
  add_foreign_key "oversized_pull_requests", "repositories"
  add_foreign_key "oversized_pull_requests", "users"
  add_foreign_key "pinned_repositories", "users"
  add_foreign_key "pr_assessments", "jev_requests"
  add_foreign_key "pr_assessments", "repositories"
  add_foreign_key "pr_assessments", "users"
  add_foreign_key "sessions", "users"
end
