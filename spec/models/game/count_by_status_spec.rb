require "rails_helper"

describe Game, ".count_by_status" do
  # Every game must land in exactly one bucket. The predicates overlap by
  # construction, so this fixture deliberately includes games that satisfy
  # several of them at once.
  #
  # update_column skips validations, which is the only way to put a game into a
  # past-dated or finished state without fighting game_starts_in_the_future and
  # the translation-completeness gate.
  let!(:plain_draft)     { create_game(:is_draft => true) }
  let!(:scheduled)       { create_game(:is_draft => false) }
  let!(:withdrawn_draft) { g = create_game(:is_draft => true);  g.update_column(:withdrawn_at, Time.now); g }
  let!(:finished)        { g = create_game(:is_draft => false); g.update_column(:author_finished_at, Time.now); g }
  let!(:running)         { g = create_game(:is_draft => false); g.update_column(:starts_at, Time.now - 1.hour); g }
  let!(:no_start_time)   { g = create_game(:is_draft => false); g.update_column(:starts_at, nil); g }

  it "puts a withdrawn game in withdrawn, whatever else it is" do
    expect(Game.count_by_status[:withdrawn]).to eq(1)
    expect(Game.count_by_status[:draft]).to eq(1)
  end

  it "counts a finished game as finished rather than running" do
    expect(Game.count_by_status[:finished]).to eq(1)
  end

  it "counts a started, unfinished game as running" do
    expect(Game.count_by_status[:running]).to eq(1)
  end

  # starts_at is nullable and Game#started? treats NULL as not started. A naive
  # `starts_at < now` in SQL evaluates NULL to unknown and silently drops the
  # row from every bucket, which is how a status table stops summing.
  it "counts a game with no start time as scheduled, not as nothing" do
    expect(Game.count_by_status[:scheduled]).to eq(2)
  end

  # The property that catches a mis-specified predicate without anyone having
  # to reason through the precedence.
  it "accounts for every game exactly once" do
    expect(Game.count_by_status.values.sum).to eq(Game.count)
  end

  it "counts locked games separately, since a game can be locked and running" do
    running.update_column(:editing_locked_at, Time.now)
    expect(Game.editing_locked_count).to eq(1)
    expect(Game.count_by_status[:running]).to eq(1)
  end
end
