# -*- encoding : utf-8 -*-
require "rails_helper"

# A commercial game admits teams through AccessPass -- an operator's invite or
# a redeemed code -- and GamePassingsController#find_or_create_game_passing
# short-circuits to #gated_passing for one, so a GameEntry authorises nothing
# there. shared/_current_games_status.html.erb has stated that invariant in a
# comment since the gated branch shipped ("a gated game never creates a
# GameEntry, so game_entry is nil here"), but nothing enforced it.
#
# Nothing had to go wrong for it to break, either: Game#started? reads
# starts_at and knows nothing about access_mode, so a gated game falls into
# Game.notstarted by construction and dashboard/_coming_games offered
# "Подать заявку" on it beside the scheduled games. Applying created a real
# entry, reserved one of the game's places (Game#reserve_place_for_team!) and
# counted towards the public participant figure (GamesHelper#game_team_counts),
# and then /play answered 401 -- so the whole flow was a promise the app could
# not keep, for the captain and for the operator who accepted it.
#
# The release actions stay open on purpose: access_mode is editable
# (GamesController#game_params, operators only), so a scheduled game carrying
# live entries can become gated under them, and a captain must still be able
# to withdraw one -- which is also what gives the reserved place back.
describe "the apply/accept flow against a gated game", type: :request do
  let(:author)  { create_user }
  let(:captain) { create_user }
  let(:team)    { create_team(:captain => captain) }
  let(:game)    { create_game(:author => author, :is_draft => false, :access_mode => "pass_required") }

  def login(user)
    post login_path, :params => { :email => user.email, :password => "1234" }
  end

  # Re-read from the database rather than through the association: the counter
  # is delegated to the current run, and a reloaded game keeps its cached one.
  def places_taken(game)
    Game.find(game.id).requested_teams_number
  end

  describe "GameEntriesController" do
    it "refuses an application to a gated game" do
      team
      login(captain)

      post new_game_entry_path(:game_id => game.id, :team_id => team.id)

      expect(response).to have_http_status(:unauthorized)
      expect(GameEntry.of_team(team).of_game(game)).to be_empty
      expect(places_taken(game)).to eq(0)
    end

    it "refuses reopening an entry left over from before the game was gated" do
      entry = create_game_entry(:game => game, :team => team, :status => "recalled")
      login(captain)

      post reopen_game_entry_path(entry)

      expect(response).to have_http_status(:unauthorized)
      expect(entry.reload.status).to eq("recalled")
      expect(places_taken(game)).to eq(0)
    end

    # The operator's half of the dead end: an "Accept" button that looks
    # exactly like granting access and grants none.
    it "refuses the author accepting an entry on a gated game" do
      entry = create_game_entry(:game => game, :team => team, :status => "new")
      login(author)

      post accept_game_entry_path(entry)

      expect(response).to have_http_status(:unauthorized)
      expect(entry.reload.status).to eq("new")
    end

    it "still lets a captain recall an entry on a gated game" do
      entry = create_game_entry(:game => game, :team => team, :status => "new")
      game.reserve_place_for_team!
      login(captain)

      post recall_game_entry_path(entry)

      expect(entry.reload.status).to eq("recalled")
      expect(places_taken(game)).to eq(0)
    end

    it "still lets a captain cancel an accepted entry on a gated game" do
      entry = create_game_entry(:game => game, :team => team, :status => "accepted")
      game.reserve_place_for_team!
      login(captain)

      post cancel_game_entry_path(entry)

      expect(entry.reload.status).to eq("canceled")
      expect(places_taken(game)).to eq(0)
    end

    it "leaves the scheduled flow untouched" do
      scheduled = create_game(:author => author, :is_draft => false)
      team
      login(captain)

      post new_game_entry_path(:game_id => scheduled.id, :team_id => team.id)

      expect(GameEntry.of_team(team).of_game(scheduled).map(&:status)).to eq(["new"])
      expect(places_taken(scheduled)).to eq(1)
    end
  end

  # The same grant, through the operator's door. Admin::GameEntriesController
  # exists because GameEntriesController#accept never rendered its button for
  # a superadmin (see that class's own comment), and it hands out exactly the
  # same worthless admission on a gated game.
  describe "Admin::GameEntriesController" do
    let(:operator) { u = create_user; u.update!(:is_superadmin => true); u }

    it "refuses accepting an entry on a gated game" do
      entry = create_game_entry(:game => game, :team => team, :status => "new")
      login(operator)

      post accept_admin_game_entry_path(game, entry)

      expect(response).to have_http_status(:unauthorized)
      expect(entry.reload.status).to eq("new")
    end

    # "Offering a control the action refuses is a promise the page cannot
    # keep" -- games/show.html.erb's own words, about its hand-over form.
    # The console still lists the stale rows and still offers the reject that
    # clears them; it just stops offering the accept that now 401s, and says
    # where a team is actually admitted from.
    it "offers no accept button on a gated game, and says where access comes from" do
      create_game_entry(:game => game, :team => team, :status => "new")
      login(operator)

      get admin_game_entries_path(game)

      expect(response.body).not_to include(I18n.t("admin.entries.accept"))
      expect(response.body).to include(I18n.t("admin.entries.reject"))
      expect(response.body).to include(I18n.t("admin.entries.gated_note"))
    end

    it "keeps the accept button on a scheduled game" do
      scheduled = create_game(:author => author, :is_draft => false)
      create_game_entry(:game => scheduled, :team => team, :status => "new")
      login(operator)

      get admin_game_entries_path(scheduled)

      expect(response.body).to include(I18n.t("admin.entries.accept"))
      expect(response.body).not_to include(I18n.t("admin.entries.gated_note"))
    end

    # Rejecting is a release, not a grant: it clears the stale row and gives
    # the reserved place back, which is the only way an operator can tidy up
    # a game that was flipped to pass_required under live applications.
    it "still lets an operator reject an entry on a gated game" do
      entry = create_game_entry(:game => game, :team => team, :status => "new")
      game.reserve_place_for_team!
      login(operator)

      post reject_admin_game_entry_path(game, entry)

      expect(entry.reload.status).to eq("rejected")
      expect(places_taken(game)).to eq(0)
    end
  end

  # Both widgets render on the dashboard AND in the team room, from the same
  # two partials -- shared/_current_games (started games) and
  # dashboard/_coming_games (everything else). A gated game lands in the
  # second by default and in the first if its start date happens to be past,
  # since neither selector consults access_mode.
  describe "the dashboard" do
    it "offers the redemption link, not an application button, for a gated game" do
      team
      game
      login(captain)

      get dashboard_path

      expect(response.body).to include(I18n.t("shared.current_games_status.redeem_code_link"))
      expect(response.body).not_to include(I18n.t("shared.game_entry_controls.apply"))
    end

    it "offers the play link when the team already holds a live pass" do
      create_access_pass(:game => game, :team => team)
      login(captain)

      get dashboard_path

      expect(response.body).to include(I18n.t("shared.current_games_status.play"))
      expect(response.body).not_to include(I18n.t("shared.current_games_status.redeem_code_link"))
    end

    # The same treatment for a gated game whose start date has passed: it is
    # `started?`, so it renders through shared/_current_games instead, which
    # passed no gated_live at all -- telling a team holding a pass to go and
    # redeem a code they do not have.
    # A level, because shared/_current_games has a no-levels branch of its own
    # that would answer this example without ever reaching the gated one.
    it "offers the play link on a gated game whose start date has passed" do
      create_level(:game => game)
      set_game_schedule!(game, :starts_at => 2.hours.ago)
      create_access_pass(:game => game, :team => team)
      login(captain)

      get dashboard_path

      expect(response.body).to include(I18n.t("shared.current_games_status.play"))
      expect(response.body).not_to include(I18n.t("shared.current_games_status.redeem_code_link"))
    end

    # An entry accepted while the game was still scheduled, on a game an
    # operator later flipped to pass_required. _current_games_status tests
    # game_entry FIRST, so passing one through offered "Играть!" to a team
    # holding no pass -- a link that answers 401.
    it "ignores an entry left over from before a started game was gated" do
      create_level(:game => game)
      set_game_schedule!(game, :starts_at => 2.hours.ago)
      create_game_entry(:game => game, :team => team, :status => "accepted")
      login(captain)

      get dashboard_path

      expect(response.body).to include(I18n.t("shared.current_games_status.redeem_code_link"))
      expect(response.body).not_to include(I18n.t("shared.current_games_status.play"))
    end

    it "still offers the application button on a scheduled game" do
      create_game(:author => author, :is_draft => false)
      team
      login(captain)

      get dashboard_path

      expect(response.body).to include(I18n.t("shared.game_entry_controls.apply"))
    end

    # GamesHelper#gated_play_status is a batched preload -- one query for the
    # whole widget. Reading it per row would reintroduce exactly the N+1
    # spec/requests/games_listing_spec.rb pins for the games listing.
    it "does not grow the query count as the number of gated rows grows" do
      create_access_pass(:game => game, :team => team)
      login(captain)
      one = count_queries { get dashboard_path }

      9.times do
        other = create_game(:is_draft => false, :access_mode => "pass_required")
        create_access_pass(:game => other, :team => team)
      end
      ten = count_queries { get dashboard_path }

      expect(ten).to eq(one)
    end
  end
end
