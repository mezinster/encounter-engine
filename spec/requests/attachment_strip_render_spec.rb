require "rails_helper"

# Task 3 review finding (Important 1): spec/views/attachment_strip_spec.rb
# only renders shared/_attachment_strip.html.erb directly, with a hand-built
# Array passed as :files -- it never goes through
# Level#attached_files_for/Hint#attached_files_for, and nothing exercises
# the two actual render call sites in show_current_level.html.erb over a
# real request. Deleting both render lines there (the level's, and the one
# inside each fired hint's fieldset) passed the entire targeted suite with
# every photograph silently gone from the page. This spec drives the real
# play screen end to end -- GET /play/:game_id, signed in as a team on its
# current level -- with a file attached to the level AND a file attached to
# a fired hint, so a dropped render call, a renamed content_locale, or a
# reshuffled .play-scroll wrapper fails a test instead of shipping unnoticed.
describe "attachment strip rendered on the real play screen", type: :request do
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "shows a file attached to the level and a file attached to a fired hint" do
    author = create_user
    game = create_game(:author => author)
    # create_game defaults starts_at to 2099 (its own validation refuses a
    # past starts_at on save) -- set_game_schedule! writes the run's column
    # directly, the same technique spec/requests/paused_hint_seeding_spec.rb
    # uses to get a game the play screen will accept as started.
    set_game_schedule!(game, :starts_at => 1.hour.ago)

    level = create_level(:game => game)
    hint = create_hint(:level => level, :delay => 0) # fires the instant the level is entered

    level_file = GameFileUpload.new(game, fixture_upload("photo.jpg"), author).call
    hint_file  = GameFileUpload.new(game, fixture_upload("map.pdf"), author).call
    expect(level_file).to be_persisted
    expect(hint_file).to be_persisted

    level.replace_attached_files([ level_file.id ], nil)
    hint.replace_attached_files([ hint_file.id ], nil)

    player = create_user
    team = create_team(:captain => player)
    create_game_entry(:game => game, :team => team)
    create_game_passing(:level => level, :team => team)

    sign_in(player)

    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(level_file.filename)
    expect(response.body).to include(hint_file.filename)
  end
end
