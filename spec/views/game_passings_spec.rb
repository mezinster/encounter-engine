# -*- encoding : utf-8 -*-
require "rails_helper"

# Controller specs never render templates in this suite (see
# spec/views/layouts_spec.rb's header comment) -- these compile and execute
# the real ERB for the 3 game_passings templates Task 9b ported, exercising
# real path helpers (show_level_log_path, show_game_log_path,
# show_full_log_path, post_answer_path, exit_game_path) and every locale key
# they read.
RSpec.describe "game_passings/index", type: :view do
  it "renders team standings, per-team log links, and the full-log link" do
    level = create_level
    game = level.game
    assign(:game, game)
    # The move control on each row needs the game's levels (Task 6); the
    # controller loads this once and hands it to the view the same way.
    assign(:levels, [level])

    in_progress = create_game_passing(level: level)
    finished = create_game_passing(level: level)
    finished.update!(finished_at: Time.current)
    exited = create_game_passing(level: level)
    exited.update!(finished_at: Time.current, status: "exited")

    assign(:game_passings, [in_progress, finished, exited])
    # The superadmin-only level-codes fieldset (Task 3) reads logged_in? and
    # current_user, same as the guest-vs-player specs below already stub for
    # game_passings/show_results.
    view.define_singleton_method(:logged_in?) { false }
    view.define_singleton_method(:current_user) { nil }

    render

    expect(rendered).to include(ERB::Util.html_escape(I18n.t("game_passings.index.title", name: game.name)))
    expect(rendered).to include(I18n.t("game_passings.index.exited"))
    expect(rendered).to include(I18n.t("game_passings.index.finished"))
    expect(rendered).to include(I18n.t("game_passings.index.level_log"))
    expect(rendered).to include(I18n.t("game_passings.index.game_log"))
    expect(rendered).to include(show_game_log_path(game_id: finished.game_id, team_id: finished.team_id))
    expect(rendered).to include(show_level_log_path(game_id: in_progress.game_id, team_id: in_progress.team_id))
    expect(rendered).to include(I18n.t("game_passings.index.full_log"))
    expect(rendered).to include(show_full_log_path(game))
  end

  # Every other GET here signs in as a plain author, and the example above
  # stubs logged_in? => false -- so the `logged_in? && current_user.superadmin?`
  # fieldset (index.html.erb:15-38) was previously rendered by nothing in the
  # suite. A renamed path helper or locale key inside it would 500 the
  # operator's only route to the mid-game code-mode intervention with rspec
  # still green -- verified by the whole-branch review (finding 4/5).
  it "shows the level-codes fieldset to a superadmin" do
    superadmin = create_user
    superadmin.update!(:is_superadmin => true)

    level = Level.create!(name: "Two codes", text: "Some text", game: create_game)
    create_question(level: level, correct_answer: "AAA")
    create_question(level: level, correct_answer: "BBB")
    game = level.game

    assign(:game, game)
    assign(:levels, [level])
    assign(:game_passings, [])
    view.define_singleton_method(:logged_in?) { true }
    view.define_singleton_method(:current_user) { superadmin }

    render

    expect(rendered).to include(I18n.t("game_passings.index.level_codes_legend"))
    expect(rendered).to include(level.any_code_passes? ? I18n.t("levels.codes_rule_any") : I18n.t("levels.codes_rule_all"))
    expect(rendered).to include(require_all_codes_level_path(game_id: game.id, id: level.id))
  end
end

RSpec.describe "game_passings/show_current_level", type: :view do
  it "renders the current level, the answer form, and the captain-only exit link" do
    captain = create_user
    team = create_team(captain: captain)
    captain.reload

    level = create_level(name: "Level One", text: "Do the thing")
    game = level.game
    game_passing = create_game_passing(level: level, team: team)

    assign(:game, game)
    assign(:game_passing, game_passing)
    view.define_singleton_method(:current_user) { captain }
    # content_locale_for is a helper_method on ApplicationController (Task 5);
    # isolated view specs don't run through the real controller stack, so it
    # has to be stubbed the same way current_user already is above. A
    # single-locale game's content locale is always its primary_locale.
    view.define_singleton_method(:content_locale_for) { |g| g.primary_locale }

    render

    expect(rendered).to include(I18n.t("game_passings.show_current_level.title_prefix"))
    expect(rendered).to include(level.name)
    expect(rendered).to include(level.text)
    expect(rendered).to include(I18n.t("game_passings.show_current_level.no_more_hints"))
    expect(rendered).to include(post_answer_path(game_id: game.id))
    expect(rendered).to include(I18n.t("game_passings.show_current_level.answer_label"))
    expect(rendered).to include(I18n.t("game_passings.show_current_level.submit"))
    expect(rendered).to include(I18n.t("game_passings.show_current_level.exit_game"))
    expect(rendered).to include(exit_game_path(game_id: game_passing.game_id))
  end

  it "renders a ready hint, wrong-answer feedback, and multi-question progress" do
    captain = create_user
    team = create_team(captain: captain)
    captain.reload

    game = create_game
    # Bypass create_level's fixture default (which itself builds one
    # question via Level#correct_answer=) so the level has exactly the two
    # questions this test asserts on.
    level = Level.create!(name: "Test level", text: "Some text", game: game)
    create_question(level: level, correct_answer: "AAA")
    create_question(level: level, correct_answer: "BBB")
    # The progress line only renders when all codes are required; any_code_passes
    # defaults to true for newly created levels.
    level.update_column(:any_code_passes, false)
    hint = create_hint(level: level, text: "Look closer", delay: 0)
    game_passing = create_game_passing(level: level, team: team)
    game_passing.answered_questions << level.questions.first
    game_passing.save!

    assign(:game, game)
    assign(:game_passing, game_passing)
    assign(:answer, "WRONG")
    assign(:answer_was_correct, false)
    view.define_singleton_method(:current_user) { captain }
    view.define_singleton_method(:content_locale_for) { |g| g.primary_locale }

    render

    expect(rendered).to include(I18n.t("game_passings.show_current_level.hint_label"))
    expect(rendered).to include(hint.text)
    expect(rendered).to include(ERB::Util.html_escape(I18n.t("game_passings.show_current_level.answer_incorrect", answer: "WRONG")))
    expect(rendered).to include(I18n.t("game_passings.show_current_level.multi_question_progress", answered: 1, total: 2))
  end

  it "hides the progress line on a multi-question level where any code passes" do
    captain = create_user
    team = create_team(captain: captain)
    captain.reload

    game = create_game
    level = Level.create!(name: "Test level", text: "Some text", game: game)
    create_question(level: level, correct_answer: "AAA")
    create_question(level: level, correct_answer: "BBB")
    # any_code_passes defaults to true for newly created levels -- this is the
    # counterpart to the "any_code_passes = false" example above, and the one
    # that proves the progress line's suppression can actually go red.
    game_passing = create_game_passing(level: level, team: team)

    assign(:game, game)
    assign(:game_passing, game_passing)
    view.define_singleton_method(:current_user) { captain }
    view.define_singleton_method(:content_locale_for) { |g| g.primary_locale }

    render

    expect(rendered).not_to include(I18n.t("game_passings.show_current_level.multi_question_progress", answered: 0, total: 2))
  end
end

RSpec.describe "game_passings/show_results", type: :view do
  it "shows the full-log link to the game's author" do
    author = create_user
    game = create_game(author: author)
    assign(:game, game)
    view.define_singleton_method(:logged_in?) { true }
    view.define_singleton_method(:current_user) { author }

    render

    expect(rendered).to include(I18n.t("game_passings.show_results.congrats"))
    expect(rendered).to include(I18n.t("game_passings.show_results.full_log"))
    expect(rendered).to include(show_full_log_path(game))
  end

  it "shows the full-log link to a player whose team genuinely finished" do
    game = create_game
    captain = create_user
    team = create_team(captain: captain)
    captain.reload
    level = create_level(game: game)
    create_game_passing(level: level, team: team, finished_at: Time.current)

    assign(:game, game)
    view.define_singleton_method(:logged_in?) { true }
    view.define_singleton_method(:current_user) { captain }

    render

    expect(rendered).to include(I18n.t("game_passings.show_results.full_log"))
  end

  it "hides the full-log link from a guest" do
    game = create_game
    assign(:game, game)
    view.define_singleton_method(:logged_in?) { false }
    view.define_singleton_method(:current_user) { nil }

    render

    expect(rendered).not_to include(I18n.t("game_passings.show_results.full_log"))
  end

  it "hides the full-log link from a team still mid-game" do
    game = create_game
    captain = create_user
    team = create_team(captain: captain)
    captain.reload
    level = create_level(game: game)
    create_game_passing(level: level, team: team)

    assign(:game, game)
    view.define_singleton_method(:logged_in?) { true }
    view.define_singleton_method(:current_user) { captain }

    render

    expect(rendered).not_to include(I18n.t("game_passings.show_results.full_log"))
  end

  it "hides the full-log link from a team that exited (collusion-bypass guard)" do
    game = create_game
    captain = create_user
    team = create_team(captain: captain)
    captain.reload
    level = create_level(game: game)
    create_game_passing(level: level, team: team, finished_at: Time.current, status: "exited")

    assign(:game, game)
    view.define_singleton_method(:logged_in?) { true }
    view.define_singleton_method(:current_user) { captain }

    render

    expect(rendered).not_to include(I18n.t("game_passings.show_results.full_log"))
  end
end
