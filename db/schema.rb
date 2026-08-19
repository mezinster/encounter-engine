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

ActiveRecord::Schema[8.0].define(version: 2026_08_19_110000) do
  create_table "access_codes", force: :cascade do |t|
    t.integer "game_id", null: false
    t.string "code_digest", null: false
    t.string "batch_key", null: false
    t.integer "issued_by_id"
    t.datetime "revoked_at"
    t.datetime "expires_at"
    t.datetime "redeemed_at"
    t.integer "access_pass_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["code_digest"], name: "index_access_codes_on_code_digest", unique: true
    t.index ["game_id", "batch_key"], name: "index_access_codes_on_game_id_and_batch_key"
  end

  create_table "access_passes", force: :cascade do |t|
    t.integer "game_id", null: false
    t.integer "team_id", null: false
    t.string "source", null: false
    t.integer "issued_by_id"
    t.datetime "revoked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["game_id", "team_id"], name: "index_access_passes_on_game_id_and_team_id"
  end

  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "admin_actions", force: :cascade do |t|
    t.integer "actor_id", null: false
    t.string "action", null: false
    t.string "target_type"
    t.integer "target_id"
    t.string "target_label"
    t.datetime "created_at", null: false
    t.string "details"
    t.string "actor_label"
    t.index ["actor_id"], name: "index_admin_actions_on_actor_id"
    t.index ["created_at"], name: "index_admin_actions_on_created_at"
  end

  create_table "answers", force: :cascade do |t|
    t.integer "question_id"
    t.integer "level_id"
    t.string "value"
  end

  create_table "content_translations", force: :cascade do |t|
    t.string "translatable_type", null: false
    t.integer "translatable_id", null: false
    t.string "field", null: false
    t.string "locale", null: false
    t.text "value"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["translatable_type", "translatable_id", "field", "locale"], name: "index_content_translations_uniqueness", unique: true
  end

  create_table "file_attachments", force: :cascade do |t|
    t.integer "game_file_id", null: false
    t.string "attachable_type", null: false
    t.integer "attachable_id", null: false
    t.string "locale"
    t.integer "position"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["attachable_type", "attachable_id"], name: "index_file_attachments_on_attachable_type_and_attachable_id"
    t.index ["game_file_id"], name: "index_file_attachments_on_game_file_id"
  end

  create_table "game_entries", force: :cascade do |t|
    t.integer "game_id"
    t.integer "team_id"
    t.string "status"
    t.integer "game_run_id"
    t.index ["game_run_id"], name: "index_game_entries_on_game_run_id"
    t.index ["team_id", "game_run_id"], name: "index_game_entries_on_team_id_and_game_run_id_live", unique: true, where: "status IN ('new', 'accepted')"
  end

  create_table "game_files", force: :cascade do |t|
    t.integer "game_id", null: false
    t.string "filename", null: false
    t.string "content_type", null: false
    t.integer "byte_size", default: 0, null: false
    t.integer "derived_byte_size", default: 0, null: false
    t.string "checksum"
    t.integer "uploaded_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["game_id", "filename"], name: "index_game_files_on_game_id_and_filename", unique: true
    t.index ["game_id"], name: "index_game_files_on_game_id"
  end

  create_table "game_locale_preferences", force: :cascade do |t|
    t.integer "user_id", null: false
    t.integer "game_id", null: false
    t.string "locale", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id", "game_id"], name: "index_game_locale_preferences_on_user_id_and_game_id", unique: true
  end

  create_table "game_passings", force: :cascade do |t|
    t.integer "game_id"
    t.integer "team_id"
    t.integer "current_level_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.datetime "finished_at", precision: nil
    t.datetime "current_level_entered_at", precision: nil
    t.text "answered_questions"
    t.string "status"
    t.integer "penalty_seconds", default: 0, null: false
    t.integer "game_run_id"
    t.integer "access_pass_id"
    t.integer "paused_seconds", default: 0, null: false
    t.index ["access_pass_id"], name: "index_game_passings_on_access_pass_id", unique: true, where: "access_pass_id IS NOT NULL"
    t.index ["game_run_id"], name: "index_game_passings_on_game_run_id"
    t.index ["team_id", "game_run_id"], name: "index_game_passings_on_team_id_and_game_run_id", unique: true
  end

  create_table "game_runs", force: :cascade do |t|
    t.integer "game_id", null: false
    t.integer "ordinal", default: 1, null: false
    t.datetime "starts_at", precision: nil
    t.datetime "registration_deadline", precision: nil
    t.integer "max_team_number"
    t.integer "requested_teams_number", default: 0
    t.datetime "author_finished_at", precision: nil
    t.boolean "is_testing", default: false, null: false
    t.datetime "test_date", precision: nil
    t.datetime "paused_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "test_token"
    t.index ["game_id", "ordinal"], name: "index_game_runs_on_game_id_and_ordinal", unique: true
    t.index ["test_token"], name: "index_game_runs_on_test_token", unique: true
  end

  create_table "games", force: :cascade do |t|
    t.string "name"
    t.string "description"
    t.integer "author_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.string "primary_locale", default: "ru", null: false
    t.string "available_locales", default: "ru", null: false
    t.datetime "editing_locked_at"
    t.datetime "withdrawn_at"
    t.string "visibility", default: "listed", null: false
    t.string "access_mode", default: "scheduled", null: false
    t.boolean "points_enabled", default: false, null: false
    t.integer "level_completion_points", default: 0, null: false
    t.integer "game_completion_points", default: 0, null: false
    t.integer "max_skips", default: 0, null: false
    t.integer "skip_points_fine", default: 0, null: false
    t.integer "skip_time_penalty", default: 0, null: false
  end

  create_table "hints", force: :cascade do |t|
    t.integer "level_id"
    t.string "text"
    t.integer "delay"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
  end

  create_table "invitations", force: :cascade do |t|
    t.integer "to_team_id"
    t.integer "for_user_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
  end

  create_table "levels", force: :cascade do |t|
    t.text "text"
    t.integer "game_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.integer "position"
    t.string "name"
    t.integer "wrong_answer_penalty", default: 0, null: false
    t.boolean "any_code_passes", default: true, null: false
    t.integer "points_award"
  end

  create_table "logs", force: :cascade do |t|
    t.integer "game_id"
    t.string "team"
    t.string "level"
    t.string "answer"
    t.datetime "time", precision: nil
    t.integer "team_id"
    t.integer "level_id"
    t.integer "game_run_id"
    t.integer "game_passing_id"
    t.index ["game_id", "team_id", "level_id"], name: "index_logs_on_game_id_and_team_id_and_level_id"
    t.index ["game_passing_id"], name: "index_logs_on_game_passing_id"
    t.index ["game_run_id"], name: "index_logs_on_game_run_id"
  end

  create_table "options", force: :cascade do |t|
    t.integer "question_id", null: false
    t.string "text", null: false
    t.boolean "is_correct", default: false, null: false
    t.integer "position"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["question_id"], name: "index_options_on_question_id"
  end

  create_table "point_transactions", force: :cascade do |t|
    t.integer "team_id", null: false
    t.integer "game_id", null: false
    t.integer "game_passing_id", null: false
    t.integer "level_id"
    t.integer "amount", null: false
    t.string "reason", null: false
    t.integer "created_by_id"
    t.datetime "created_at", null: false
    t.index ["game_passing_id", "level_id", "reason"], name: "index_point_transactions_per_level", unique: true, where: "level_id IS NOT NULL"
    t.index ["game_passing_id", "reason"], name: "index_point_transactions_per_attempt", unique: true, where: "level_id IS NULL"
    t.index ["team_id"], name: "index_point_transactions_on_team_id"
  end

  create_table "questions", force: :cascade do |t|
    t.string "questions"
    t.integer "level_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
  end

  create_table "settings", force: :cascade do |t|
    t.string "name", null: false
    t.integer "value"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "string_value"
    t.index ["name"], name: "index_settings_on_name", unique: true
  end

  create_table "team_join_requests", force: :cascade do |t|
    t.integer "user_id", null: false
    t.integer "team_id", null: false
    t.string "status", default: "new", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["team_id", "status"], name: "index_team_join_requests_on_team_id_and_status"
    t.index ["user_id", "team_id"], name: "index_team_join_requests_on_user_id_and_team_id_pending", unique: true, where: "status = 'new'"
  end

  create_table "teams", force: :cascade do |t|
    t.string "name"
    t.integer "captain_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
  end

  create_table "test_admissions", force: :cascade do |t|
    t.integer "game_run_id", null: false
    t.integer "team_id", null: false
    t.integer "user_id"
    t.datetime "created_at", null: false
    t.index ["game_run_id", "team_id"], name: "index_test_admissions_on_run_and_team", unique: true
    t.index ["game_run_id", "user_id"], name: "index_test_admissions_on_run_and_user", unique: true, where: "user_id IS NOT NULL"
  end

  create_table "translation_proposals", force: :cascade do |t|
    t.integer "translation_run_id", null: false
    t.string "translatable_type", null: false
    t.integer "translatable_id", null: false
    t.string "field", null: false
    t.string "locale", null: false
    t.text "source_text", null: false
    t.text "proposed_text", null: false
    t.string "flags"
    t.string "state", default: "pending", null: false
    t.integer "reviewed_by_id"
    t.datetime "reviewed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "accepted_text"
    t.index ["translation_run_id", "state"], name: "index_translation_proposals_on_translation_run_id_and_state"
    t.index ["translation_run_id", "translatable_type", "translatable_id", "field", "locale"], name: "index_translation_proposals_unique_field", unique: true
  end

  create_table "translation_runs", force: :cascade do |t|
    t.integer "game_id", null: false
    t.integer "actor_id", null: false
    t.string "model", null: false
    t.string "state", default: "pending", null: false
    t.string "target_locales", default: "", null: false
    t.integer "fields_total", default: 0, null: false
    t.integer "fields_done", default: 0, null: false
    t.integer "fields_failed", default: 0, null: false
    t.integer "estimated_input_tokens", default: 0, null: false
    t.integer "input_tokens", default: 0, null: false
    t.integer "output_tokens", default: 0, null: false
    t.integer "cache_read_tokens", default: 0, null: false
    t.text "error_message"
    t.datetime "started_at"
    t.datetime "finished_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["game_id", "state"], name: "index_translation_runs_on_game_id_and_state"
    t.index ["game_id"], name: "index_translation_runs_one_active_per_game", unique: true, where: "state IN ('pending', 'running')"
  end

  create_table "users", force: :cascade do |t|
    t.string "email"
    t.string "nickname"
    t.string "crypted_password"
    t.string "salt"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.integer "team_id"
    t.date "date_of_birth"
    t.string "phone_number"
    t.string "locale"
    t.boolean "is_superadmin", default: false, null: false
    t.string "timezone"
    t.string "instagram"
    t.string "telegram_id"
    t.boolean "on_telegram", default: false, null: false
    t.boolean "on_whatsapp", default: false, null: false
    t.boolean "on_viber", default: false, null: false
    t.boolean "on_signal", default: false, null: false
    t.boolean "on_max", default: false, null: false
    t.string "session_token"
    t.string "password_digest"
    t.string "reset_password_token_digest"
    t.datetime "reset_password_sent_at"
    t.boolean "is_operator", default: false, null: false
    t.index ["reset_password_token_digest"], name: "index_users_on_reset_password_token_digest"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
end
