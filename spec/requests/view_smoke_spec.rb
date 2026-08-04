# -*- encoding : utf-8 -*-
require "rails_helper"

# Task 9c fix round 1: real, full-stack HTTP requests (not view specs, not
# controller specs -- neither renders through the real helper-inclusion or
# layout-partial-lookup machinery the way an actual request does). These are
# the only kind of test that would have caught either of the two bugs a
# reviewer found:
#
# 1. app/helpers/global_helpers.rb (now application_helper.rb) never matched
#    Rails' `**/*_helper.rb` auto-helper glob, so error_messages_for was
#    undefined on every real GET to a template that calls it.
# 2. app/views/layouts/application.html.erb called `render "header"` /
#    `render "left_menu"` with no `layouts/` prefix -- layout partial lookup
#    uses the rendering controller's own view-path prefixes, not the
#    layout's own directory, so every real request raised
#    `ActionView::MissingTemplate` looking for e.g. "users/_header" instead
#    of "layouts/_header".
#
# Every path below is either directly in Task 9c's 18-template scope or
# renders through the shared layout that scope depends on.
RSpec.describe "view smoke test", type: :request do
  def login(user)
    post login_path, params: { email: user.email, password: "1234" }
  end

  it "GET /signup renders 200 (guest chrome + error_messages_for)" do
    get signup_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t("users.new.submit"))
  end

  it "GET /games/new renders 200 (authenticated chrome + error_messages_for)" do
    user = create_user
    login(user)

    get new_game_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t("games.new.submit"))
  end

  it "GET /games/:id/edit renders 200" do
    author = create_user
    login(author)
    game = create_game(author: author)

    get edit_game_path(game)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t("games.edit.submit"))
  end

  it "GET /games/:game_id/levels/new renders 200" do
    author = create_user
    login(author)
    game = create_game(author: author)

    get new_game_level_path(game)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t("levels.new.submit"))
  end

  it "GET /games/:game_id/levels/:id/edit renders 200" do
    author = create_user
    login(author)
    game = create_game(author: author)
    level = create_level(game: game)

    get edit_game_level_path(game, level)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t("levels.edit.submit"))
  end

  it "GET /games/:game_id/levels/:level_id/hints/new renders 200" do
    author = create_user
    login(author)
    game = create_game(author: author)
    level = create_level(game: game)

    get new_game_level_hint_path(game, level)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t("hints.new.submit"))
  end

  it "GET /games/:game_id/levels/:level_id/hints/:id/edit renders 200" do
    author = create_user
    login(author)
    game = create_game(author: author)
    level = create_level(game: game)
    hint = create_hint(level: level)

    get edit_game_level_hint_path(game, level, hint)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t("hints.edit.submit"))
  end

  it "GET /games/:game_id/levels/:level_id/questions/new renders 200" do
    author = create_user
    login(author)
    game = create_game(author: author)
    level = create_level(game: game)

    get new_game_level_question_path(game, level)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t("questions.new.submit"))
  end

  it "GET .../questions/:question_id/answers renders 200" do
    author = create_user
    login(author)
    game = create_game(author: author)
    level = create_level(game: game)
    question = level.questions.first

    get game_level_question_answers_path(game, level, question)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t("answers.index.submit"))
  end

  it "GET /users/:id/edit renders 200" do
    user = create_user
    login(user)

    get edit_user_path(user)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t("users.edit.submit"))
  end

  it "GET /dashboard renders 200, exercising the authenticated layout chrome" do
    user = create_user
    login(user)

    get dashboard_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t("dashboard.index.greeting"))
  end
end
