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

ActiveRecord::Schema[8.0].define(version: 2026_08_08_062600) do
  create_table "admin_actions", force: :cascade do |t|
    t.integer "actor_id", null: false
    t.string "action", null: false
    t.string "target_type"
    t.integer "target_id"
    t.string "target_label"
    t.datetime "created_at", null: false
    t.string "details"
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

  create_table "game_entries", force: :cascade do |t|
    t.integer "game_id"
    t.integer "team_id"
    t.string "status"
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
  end

  create_table "games", force: :cascade do |t|
    t.string "name"
    t.string "description"
    t.integer "author_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.datetime "starts_at", precision: nil
    t.boolean "is_draft", default: false, null: false
    t.integer "max_team_number"
    t.integer "requested_teams_number", default: 0
    t.datetime "registration_deadline", precision: nil
    t.datetime "author_finished_at", precision: nil
    t.boolean "is_testing", default: false, null: false
    t.datetime "test_date", precision: nil
    t.string "primary_locale", default: "ru", null: false
    t.string "available_locales", default: "ru", null: false
    t.datetime "editing_locked_at"
    t.datetime "withdrawn_at"
    t.datetime "paused_at"
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
  end

  create_table "logs", force: :cascade do |t|
    t.integer "game_id"
    t.string "team"
    t.string "level"
    t.string "answer"
    t.datetime "time", precision: nil
    t.integer "team_id"
    t.integer "level_id"
    t.index ["game_id", "team_id", "level_id"], name: "index_logs_on_game_id_and_team_id_and_level_id"
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

  create_table "questions", force: :cascade do |t|
    t.string "questions"
    t.integer "level_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
  end

  create_table "teams", force: :cascade do |t|
    t.string "name"
    t.integer "captain_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
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
    t.index ["reset_password_token_digest"], name: "index_users_on_reset_password_token_digest"
  end
end
