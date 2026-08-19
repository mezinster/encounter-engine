require "rails_helper"

describe "playing a game that has been withdrawn", type: :request do
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  # A real team with a captain, mid-run, on a started game.
  def team_mid_run
    captain = create_user
    team    = create_team(:captain => captain)
    game    = create_game(:max_skips => 2)
    one     = create_level(:game => game, :position => 1)
    create_level(:game => game, :position => 2)
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    passing = create_game_passing(:level => one, :team => team)
    [ game.reload, passing, captain ]
  end

  it "shows the reason on the play screen instead of the level" do
    game, _passing, captain = team_mid_run
    game.withdraw!(:category => "technical", :note => "Код на точке 4 неверный",
                   :mode => "freeze")
    sign_in(captain)

    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t("games.withdrawal.categories.technical"))
    expect(response.body).to include("Код на точке 4 неверный")
  end

  it "refuses an answer, and the team lands on the explanation" do
    game, passing, captain = team_mid_run
    level_before = passing.current_level
    game.withdraw!(:category => "safety", :mode => "freeze")
    sign_in(captain)

    post post_answer_path(:game_id => game.id), :params => { :answer => "anything" }

    expect(response).to redirect_to(show_current_level_path(:game_id => game.id))
    expect(passing.reload.current_level).to eq(level_before)
  end

  it "refuses a skip" do
    game, passing, captain = team_mid_run
    game.withdraw!(:category => "weather", :mode => "freeze")
    sign_in(captain)

    post skip_level_path(:game_id => game.id)

    expect(response).to redirect_to(show_current_level_path(:game_id => game.id))
    expect(PointTransaction.where(:game_passing_id => passing.id).count).to eq(0)
  end

  it "lets the team play again once the game is restored, on the level they were on" do
    game, passing, captain = team_mid_run
    level_before = passing.current_level
    game.withdraw!(:category => "technical", :mode => "freeze")
    game.restore!
    sign_in(captain)

    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include(I18n.t("games.withdrawal.categories.technical"))
    expect(passing.reload.current_level).to eq(level_before)
  end

  # The note is operator-authored free text on a page a team reads mid-race.
  it "escapes markup in the note" do
    game, _passing, captain = team_mid_run
    game.withdraw!(:category => "other", :note => "<script>alert(1)</script>",
                   :mode => "freeze")
    sign_in(captain)

    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("<script>alert(1)</script>")
    expect(response.body).to include("&lt;script&gt;")
  end

  # The other two refusals section 6 of the spec asks for. Both behaved
  # correctly from the day the filter landed; nothing pinned them, and a
  # refusal nobody drives is a refusal that can be deleted by accident.
  it "refuses a quit, and the team lands on the explanation" do
    game, passing, captain = team_mid_run
    game.withdraw!(:category => "safety", :mode => "freeze")
    sign_in(captain)

    post exit_game_path(:game_id => game.id)

    expect(response).to redirect_to(show_current_level_path(:game_id => game.id))
    expect(passing.reload.exited?).to be false
  end

  # A GET, so it gets the notice rather than the redirect -- and it must NOT
  # get the skip confirmation, which is one button away from spending a skip.
  it "shows the explanation instead of the skip confirmation" do
    game, _passing, captain = team_mid_run
    game.withdraw!(:category => "weather", :note => "Гроза над точкой 3",
                   :mode => "freeze")
    sign_in(captain)

    get confirm_skip_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t("game_passings.withdrawn.title"))
    expect(response.body).not_to include(I18n.t("game_passings.confirm_skip.title"))
  end

  # F1 of the whole-branch review, and the reason it was invisible: NOTHING on
  # the play path read `status`. GamesController#end_game closes runs exactly
  # the same way and is safe only because it ALSO stamps author_finished_at,
  # which ensure_game_not_finished_by_author reads -- an invariant enforced by
  # a neighbouring column rather than by the column that means it.
  # withdraw!(mode: "ended") has no such neighbour, so restore! -- the only
  # button the admin console offers a withdrawn game -- put every closed run
  # back on the road, with the whole outage charged to its hint clock.
  describe "a run the withdrawal ended, after the game is restored" do
    def ended_and_restored
      game, passing, captain = team_mid_run
      game.withdraw!(:category => "cancelled", :mode => "ended")
      game.restore!
      [ game, passing, captain ]
    end

    it "refuses the correct code, and the run stays where the operator left it" do
      game, passing, captain = ended_and_restored
      level_before = passing.current_level
      sign_in(captain)

      post post_answer_path(:game_id => game.id),
           :params => { :answer => level_before.correct_answer }

      expect(response).to have_http_status(:unauthorized)
      expect(passing.reload.current_level).to eq(level_before)
      expect(passing.status).to eq("ended")
    end

    it "refuses the play screen rather than serving the level" do
      game, passing, captain = ended_and_restored
      sign_in(captain)

      get show_current_level_path(:game_id => game.id)

      expect(response).to have_http_status(:unauthorized)
      expect(response.body).not_to include(passing.current_level.name)
    end

    it "refuses a skip" do
      game, passing, captain = ended_and_restored
      sign_in(captain)

      post skip_level_path(:game_id => game.id)

      expect(response).to have_http_status(:unauthorized)
      expect(PointTransaction.where(:game_passing_id => passing.id).count).to eq(0)
    end

    # The documented way back, and the positive control for the three
    # refusals above: reinstate! is an existing, audited intervention that
    # also resets the level clock, so the team returns without the outage on
    # their countdown.
    it "plays again once the operator reinstates the team" do
      game, passing, captain = ended_and_restored
      level_before = passing.current_level
      # reload first: withdraw! ended the row in the database through its own
      # object, and save! writes only attributes this one thinks it changed.
      passing.reload.reinstate!
      sign_in(captain)

      post post_answer_path(:game_id => game.id),
           :params => { :answer => level_before.correct_answer }

      expect(response).to have_http_status(:ok)
      expect(passing.reload.current_level).not_to eq(level_before)
    end
  end

  # F3 of the whole-branch review. halt_if_withdrawn has to run BEFORE
  # find_or_create_game_passing -- that filter CREATES a passing, so halting
  # after it would enrol a team in a withdrawn game merely for reading the
  # notice -- but it therefore also runs before the three filters that refuse
  # everyone else, and each of them was a 401 before this branch. The note is
  # what an operator types under stress: a cordoned location, a police
  # instruction, sometimes a name.
  describe "the operator's note" do
    # A method rather than a constant: Ruby's lexical scope puts a constant
    # assigned inside `describe` onto Object.
    def secret_note
      "Улица перекрыта полицией, Иванов"
    end

    def withdrawn_game_with_a_note
      game, passing, captain = team_mid_run
      game.withdraw!(:category => "safety", :note => secret_note, :mode => "freeze")
      [ game, passing, captain ]
    end

    it "reaches the team playing the game" do
      game, _passing, captain = withdrawn_game_with_a_note
      sign_in(captain)

      get show_current_level_path(:game_id => game.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(secret_note)
    end

    # The other side of the participation test, and the reason it cannot simply
    # be "has a passing": an accepted team that had not opened the play screen
    # yet has no row, and falling through for them would hand them to
    # find_or_create_game_passing -- which CREATES one. That would both let
    # them play a withdrawn game and enrol them in it, which is exactly what
    # the filter's placement exists to prevent.
    it "reaches an accepted team that had not started yet, without enrolling them" do
      game, _passing, _captain = withdrawn_game_with_a_note
      latecomer = create_user
      team = create_team(:captain => latecomer)
      create_game_entry(:game => game, :team => team)
      sign_in(latecomer)

      expect {
        get show_current_level_path(:game_id => game.id)
      }.not_to change { GamePassing.count }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(secret_note)
      expect(response.body).not_to include(I18n.t("game_passings.show_current_level.answer_label"))
    end

    it "does not reach a signed-in stranger with no entry for the game" do
      game, _passing, _captain = withdrawn_game_with_a_note
      stranger = create_user
      create_team(:captain => stranger)
      sign_in(stranger)

      get show_current_level_path(:game_id => game.id)

      expect(response).to have_http_status(:unauthorized)
      expect(response.body).not_to include(secret_note)
    end

    it "does not reach the game's own author" do
      game, _passing, _captain = withdrawn_game_with_a_note
      sign_in(game.author)

      get show_current_level_path(:game_id => game.id)

      expect(response).to have_http_status(:unauthorized)
      expect(response.body).not_to include(secret_note)
    end

    it "does not reach a team that has already left the race" do
      game, passing, captain = withdrawn_game_with_a_note
      passing.exit!
      sign_in(captain)

      get show_current_level_path(:game_id => game.id)

      expect(response).to have_http_status(:unauthorized)
      expect(response.body).not_to include(secret_note)
    end
  end
  # F3 and F4 of the whole-branch review. team_owed_the_notice? asked "does
  # this team have a passing that is not exited?", which is true of a FINISHED
  # one -- so withdrawing a paid game at 02:00, after five of eight teams had
  # crossed the line, replaced every one of those five results with "Игра
  # остановлена" and the operator's incident note. A withdrawal cannot change
  # the result of a team that already finished, and the note is described in
  # that method's own comment as being only for the teams the notice is FOR.
  describe "a team the notice is not for" do
    def gated_game_with_a_finished_team
      captain = create_user
      team    = create_team(:captain => captain)
      game    = create_game(:access_mode => "pass_required")
      one     = create_level(:game => game, :position => 1)
      create_level(:game => game, :position => 2)
      set_game_schedule!(game, :starts_at => 1.hour.ago)
      pass    = create_access_pass(:game => game.reload, :team => team)
      passing = create_game_passing(:game => game, :team => team, :game_run => nil,
                                    :access_pass => pass, :level => one)
      passing.update!(:finished_at => 30.minutes.ago)
      [ game, team, captain, pass, passing ]
    end

    it "shows a finished paying team their result rather than the notice" do
      game, _team, captain, _pass, passing = gated_game_with_a_finished_team
      game.withdraw!(:category => "safety", :note => "Улица перекрыта полицией",
                     :mode => "ended")
      sign_in(captain)

      get show_current_level_path(:game_id => game.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("game_passings.gated_finish.title"))
      expect(response.body).not_to include(I18n.t("game_passings.withdrawn.title"))
      expect(response.body).not_to include("Улица перекрыта полицией")
      expect(game.reload.pass_standings.map(&:id)).to include(passing.id)
    end

    # The same population on the free path: the method is shared, and a team
    # that crossed the line on a scheduled game is no more affected by the
    # withdrawal than a paying one.
    it "shows a finished team on a scheduled game their results" do
      game, passing, captain = team_mid_run
      passing.update!(:finished_at => 30.minutes.ago)
      game.withdraw!(:category => "weather", :note => "Гроза над точкой 3",
                     :mode => "ended")
      sign_in(captain)

      get show_current_level_path(:game_id => game.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("game_passings.show_results.congrats"))
      expect(response.body).not_to include("Гроза над точкой 3")
    end

    # F4: the operator deliberately took this team's access away, which makes
    # them the clearest case of a team the incident note is not for -- and
    # revocation, not the withdrawal, is why they cannot play.
    it "does not reach a team whose pass was revoked" do
      game, _team, captain, pass, passing = gated_game_with_a_finished_team
      passing.update!(:finished_at => nil)
      pass.update!(:revoked_at => Time.now)
      game.withdraw!(:category => "other", :note => "Улица перекрыта полицией",
                     :mode => "freeze")
      sign_in(captain)

      get show_current_level_path(:game_id => game.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("errors.access_revoked"))
      expect(response.body).not_to include("Улица перекрыта полицией")
    end

    # The positive control for all three: a team still ON THE COURSE is
    # exactly who the notice is for, and must keep getting it.
    it "still reaches a paying team that is mid-run" do
      game, _team, captain, _pass, passing = gated_game_with_a_finished_team
      passing.update!(:finished_at => nil)
      game.withdraw!(:category => "safety", :note => "Улица перекрыта полицией",
                     :mode => "freeze")
      sign_in(captain)

      get show_current_level_path(:game_id => game.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Улица перекрыта полицией")
    end
  end
end
