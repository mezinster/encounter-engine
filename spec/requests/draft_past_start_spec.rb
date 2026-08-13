require "rails_helper"

# Reported from production on 2026-08-10: a game showing the ЧЕРНОВИК badge and
# an active "Завершить игру" button at the same time.
#
# The cause was #started? being purely time-based while #status gives draft
# precedence, so a draft that had simply aged past its own start date read as
# running to every control and as a draft to the badge. The expensive half was
# not the badge: ensure_game_was_not_started guards edit, update, levels and
# quiz imports off the same predicate, and it has no superadmin exemption, so
# the draft could not be edited or published by anyone.
#
# These are the consequences, asserted at the level a person actually meets
# them. See spec/models/game/started_spec.rb for the predicate itself.
describe "a draft whose start date has passed", type: :request do
  let(:author)     { create_user }
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }

  # Written directly rather than through a normal save. That used to be the
  # only way in at all -- game_starts_in_the_future refused a past start on
  # save -- and since 2026-08-13 drafts are exempt from that check, so an
  # ordinary save would work too. Kept as a direct write because "the clock
  # moved" is what this spec is reproducing, and arranging it by the same
  # route the app uses would blur arrangement into behaviour.
  #
  # Through set_game_schedule! rather than game.update_column: starts_at now
  # lives on the game's run, and update_column writes the game's own column,
  # which nothing reads. That would leave this game's real start date at its
  # default of 2099 -- so every example below would still pass, while testing
  # a game that has NOT aged past its start date. A regression test that
  # silently stops reproducing its bug is worse than one that fails.
  let(:game) do
    g = create_game(:author => author, :is_draft => true)
    set_game_schedule!(g, :starts_at => 30.minutes.ago)
    g.reload
  end

  def login_as(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  # Guards the arrangement above, not the behaviour. Every example here would
  # pass on a game that had never aged past its start date -- the bug simply
  # would not be reproduced. This fails loudly if the schedule ever stops
  # landing where #started? reads it.
  it "really is a draft whose start date has passed" do
    expect(game.starts_at).to be < Time.now
    expect(game).to be_draft
  end

  describe "its author" do
    before { game and login_as(author) }

    it "can still open the edit form" do
      get edit_game_path(game)
      expect(response).to have_http_status(:ok)
    end

    it "can still add a level" do
      get new_game_level_path(game)
      expect(response).to have_http_status(:ok)
    end

    it "can still import questions" do
      get new_game_quiz_import_path(game)
      expect(response).to have_http_status(:ok)
    end

    # The point of the whole fix: the draft can be published again. Without it
    # the author could not clear is_draft, so the game was unrecoverable.
    it "can publish it by moving the start date" do
      patch game_path(game), :params => {
        :game => { :starts_at => 1.day.from_now.strftime("%Y-%m-%d %H:%M"), :is_draft => "0" }
      }

      expect(game.reload.draft?).to be_falsey
    end

    # The counterpart, and the property that makes the 2026-08-13 draft
    # exemption safe rather than a hole: a draft may CARRY a past start date,
    # but it may not be PUBLISHED with one. game_starts_in_the_future reads
    # the value being saved, so a game going draft -> published is not a draft
    # by the time the check runs.
    #
    # Without this, the exemption would silently let a game go live already
    # started, which is the state the validation existed to prevent in the
    # first place.
    it "cannot publish it WITHOUT moving the start date" do
      patch game_path(game), :params => { :game => { :is_draft => "0" } }

      expect(game.reload.draft?).to be_truthy
    end
  end

  # Not a redundant restatement of the author case: this filter is the one with
  # no superadmin escape hatch, so before the fix the operator brought in to
  # rescue such a game was refused too.
  it "is editable by a superadmin as well" do
    game
    login_as(superadmin)

    get edit_game_path(game)

    expect(response).to have_http_status(:ok)
  end

  describe "on the author's dashboard" do
    before { game and login_as(author) }

    it "offers none of the running-game controls" do
      get dashboard_path

      expect(response.body).not_to include(I18n.t("games.list.end_game"))
      expect(response.body).not_to include(I18n.t("games.list.stats"))
      expect(response.body).not_to include(I18n.t("games.list.live_channel"))
    end
  end
end
