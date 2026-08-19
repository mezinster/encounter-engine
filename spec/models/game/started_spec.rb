# -*- encoding : utf-8 -*-
require "rails_helper"

describe Game, '#started?' do
  before :each do
    tomorrow = DateTime.now + 1
    @game = create_game :starts_at => tomorrow
  end

  describe "when game start date is in future" do
    it "returns false" do
      @game.started?.should be_falsey
    end
  end

  describe "when game start date is in the past" do
    before :each do
      day_after_tomorrow = DateTime.now + 2
      allow(Time).to receive(:now).and_return(day_after_tomorrow)
    end

    it "returns true" do
      @game.started?.should be_truthy
    end
  end

  describe "when game start date is not set" do
    before :each do
      @game.starts_at = nil
    end

    it "returns false" do
      @game.started?.should be_falsey
    end
  end

  # A draft is unpublished, so it has not begun whatever the clock says: the
  # start date on a draft is a plan, not an event.
  #
  # This is not a hypothetical state. game_starts_in_the_future only runs on
  # save, so a draft saved with a start date in the future simply AGES past it
  # -- no unusual action required, and #count_by_status's comment ("a draft has
  # no start time in the past") was relying on an invariant nothing enforces.
  #
  # What it cost before the guard below: the badge read ЧЕРНОВИК from #status,
  # which gives draft precedence, while every control keyed off #started?
  # behaved as though the game were running -- games/_list offered "Завершить
  # игру", the stats, live channel and log links appeared, and
  # ensure_game_was_not_started answered 401 to the author's own edit, add
  # level and quiz import. That filter has no superadmin exemption, so the
  # draft was locked for everyone. See spec/requests/draft_past_start_spec.rb.
  describe "when the game is a draft whose start date has passed" do
    before :each do
      @game.update!(:visibility => "draft")
      # Past validations, exactly as real time does it: the row was valid when
      # saved and the clock moved afterwards. update! would be refused by
      # game_starts_in_the_future, which is the whole reason this state is
      # only reachable by waiting.
      #
      # set_game_schedule!, not game.update_column: starts_at lives on the
      # game's run, and update_column would write the game's own column, which
      # nothing reads -- leaving this game's real start date at 2099 and this
      # example passing without ever reproducing the state it names.
      set_game_schedule!(@game, :starts_at => 30.minutes.ago)
      @game.reload
    end

    it "returns false" do
      expect(@game.started?).to be_falsey
    end

    it "still reports :draft rather than :running" do
      expect(@game.status).to eq(:draft)
    end
  end

  # The counterpart, and the reason the guard tests draft? rather than
  # something broader: withdrawing is what an operator does TO a running game,
  # so a withdrawn game has very much started. ensure_game_is_live excludes it
  # separately, which is where that distinction belongs.
  describe "when the game was withdrawn after starting" do
    before :each do
      set_game_schedule!(@game, :starts_at => 30.minutes.ago)
      @game.withdraw!(:category => "other", :mode => "freeze")
      @game.reload
    end

    it "still returns true" do
      expect(@game.started?).to be_truthy
    end
  end
end
