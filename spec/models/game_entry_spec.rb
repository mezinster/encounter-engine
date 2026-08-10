# -*- encoding : utf-8 -*-
require "rails_helper"

# db/migrate/20260810180000_move_game_entries_unique_index_to_run.rb moves the
# unique index from (team_id, game_id) to (team_id, game_run_id), still scoped
# to the "live" statuses ("new", "accepted") -- the same two
# GameEntriesController treats as occupying a slot. This is the database-level
# backstop behind GameEntriesController#new's existence check: even a request
# that bypasses the controller (a console script, a future code path) cannot
# leave a team holding two simultaneously-live entries for one RUN.
#
# It was scoped to the game until phase 3. Run 1's entries stay "accepted" for
# ever, so on a game with a second run that scope barred every returning team
# from applying again -- see the migration's own comment.
describe GameEntry do
  describe "uniqueness of a live entry per (team, run)" do
    it "rejects a second live entry for the same team and run" do
      game = create_game
      team = create_team

      GameEntry.create!(:game => game, :game_run => game.current_run,
                        :team => team, :status => "new")

      expect {
        GameEntry.create!(:game => game, :game_run => game.current_run,
                          :team => team, :status => "accepted")
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    # The whole point of moving the index: a team that played an earlier run
    # must be able to hold a live entry in a later one.
    it "allows a live entry in each of two runs of the same game" do
      game = create_game
      team = create_team
      first_run = game.current_run

      GameEntry.create!(:game => game, :game_run => first_run,
                        :team => team, :status => "accepted")
      second = game.open_run!(:starts_at => 2.years.from_now,
                              :registration_deadline => 23.months.from_now,
                              :max_team_number => 10)

      expect {
        GameEntry.create!(:game => game, :game_run => second,
                          :team => team, :status => "new")
      }.not_to raise_error
    end

    # The index is intentionally NOT a blanket uniqueness constraint: it must
    # not reject the legacy pattern GameEntry.of's comment documents and
    # spec/requests/game_registration_enforcement_spec.rb pins -- an entry
    # the author rejected, followed by a later entry for the same team that
    # was accepted. Only one of the two rows is ever "live" at a time.
    it "still allows a rejected entry to coexist with a later accepted one" do
      game = create_game
      team = create_team

      GameEntry.create!(:game => game, :game_run => game.current_run,
                        :team => team, :status => "rejected")

      expect {
        GameEntry.create!(:game => game, :game_run => game.current_run,
                          :team => team, :status => "accepted")
      }.not_to raise_error
    end
  end
end
