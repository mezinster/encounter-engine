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

ActiveRecord::Schema[8.0].define(version: 2026_08_04_100155) do
  create_table "answers", force: :cascade do |t|
    t.integer "question_id"
    t.integer "level_id"
    t.string "value"
  end

  create_table "game_entries", force: :cascade do |t|
    t.integer "game_id"
    t.integer "team_id"
    t.string "status"
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
  end

  create_table "logs", force: :cascade do |t|
    t.integer "game_id"
    t.string "team"
    t.string "level"
    t.string "answer"
    t.datetime "time", precision: nil
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
    t.string "jabber_id"
    t.string "icq_number"
    t.date "date_of_birth"
    t.string "phone_number"
    t.string "locale"
  end
end
