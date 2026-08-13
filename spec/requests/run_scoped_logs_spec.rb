# -*- encoding : utf-8 -*-
require "rails_helper"

# The §9 deferral from phase 3: after a second run opens, an author could not
# review the first run's answers at all -- every log screen showed the current
# run and nothing else.
#
# No started-run guard applies to these screens (they are gated by
# ensure_author and ensure_full_log_access), so unlike the results page there
# is no run they will name but refuse to serve.
describe "logs scoped to a run", type: :request do
  let(:author) { create_user }
  let(:game) do
    g = create_game(:author => author, :is_draft => false)
    set_game_schedule!(g, :starts_at => 2.days.ago)
    g
  end
  let(:level) { create_level(:game => game) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  # A team with a passing and a log in the run that is current at the time.
  def team_playing(run, answer)
    team = create_team(:captain => create_user)
    create_game_passing(:level => level, :team => team, :game_run => run)
    create_log(:game => game, :level => level, :team => team,
               :game_run => run, :answer => answer)
    team
  end

  def open_and_start_second_run
    game.open_run!(:starts_at => 2.years.from_now,
                   :registration_deadline => 23.months.from_now,
                   :max_team_number => 10)
    game.reload
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    game.reload
  end

  it "shows the current run's answers in the live channel by default" do
    first_run = game.current_run
    team_playing(first_run, "старыйкод")
    open_and_start_second_run
    team_playing(game.current_run, "новыйкод")
    sign_in(author)

    get show_live_channel_path(:game_id => game.id)

    expect(response.body).to include("новыйкод")
    expect(response.body).not_to include("старыйкод")
  end

  it "shows an earlier run's answers when asked by ordinal" do
    first_run = game.current_run
    team_playing(first_run, "старыйкод")
    open_and_start_second_run
    team_playing(game.current_run, "новыйкод")
    sign_in(author)

    get show_live_channel_path(:game_id => game.id, :run => 1)

    expect(response.body).to include("старыйкод")
    expect(response.body).not_to include("новыйкод")
  end

  it "shows an earlier run in the full log too" do
    first_run = game.current_run
    team_playing(first_run, "старыйкод")
    open_and_start_second_run
    team_playing(game.current_run, "новыйкод")
    sign_in(author)

    get show_full_log_path(:game_id => game.id, :run => 1)

    expect(response.body).to include("старыйкод")
    expect(response.body).not_to include("новыйкод")
  end

  # @teams was built from game_passings.game_id -- game-scoped -- so the full
  # log listed a column for every team that ever played, whichever run was
  # being shown.
  it "shows only the chosen run's teams as columns in the full log" do
    first_run = game.current_run
    old_team = team_playing(first_run, "старыйкод")
    open_and_start_second_run
    new_team = team_playing(game.current_run, "новыйкод")
    sign_in(author)

    get show_full_log_path(:game_id => game.id)

    expect(response.body).to include(new_team.name)
    expect(response.body).not_to include(old_team.name)
  end

  it "falls back to the current run for an unknown ordinal" do
    first_run = game.current_run
    team_playing(first_run, "старыйкод")
    open_and_start_second_run
    team_playing(game.current_run, "новыйкод")
    sign_in(author)

    get show_live_channel_path(:game_id => game.id, :run => 99)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("новыйкод")
  end

  it "falls back for a malformed ordinal" do
    team_playing(game.current_run, "новыйкод")
    sign_in(author)

    get show_live_channel_path(:game_id => game.id, :run => "не-число")

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("новыйкод")
  end

  # A scalar ordinal is not the only shape a URL can carry: ?run[x]=1 arrives
  # as ActionController::Parameters and ?run[]=1 as an Array, and #to_i raises
  # NoMethodError on both. That was a 500 from a mistyped URL. On the file
  # DELIVERY route the same bug was worse -- it 500'd for a real file id and
  # 404'd for a fake one, which told an id-enumerating attacker which guesses
  # were right -- and this controller carries the identical line, so it gets
  # the identical guard and a test of its own.
  it "falls back for a non-scalar run param rather than raising" do
    team_playing(game.current_run, "новыйкод")
    sign_in(author)

    get show_live_channel_path(:game_id => game.id), :params => { :run => { "x" => "1" } }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("новыйкод")
  end

  it "falls back for an array run param rather than raising" do
    team_playing(game.current_run, "новыйкод")
    sign_in(author)

    get show_live_channel_path(:game_id => game.id), :params => { :run => [ "1" ] }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("новыйкод")
  end
end
