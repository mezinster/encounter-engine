require "rails_helper"

describe Game, "#status" do
  # A running game fails its own validations (game_starts_in_the_future fires
  # when author_finished_at is nil and starts_at is past), so every write to a
  # live game row goes through update_column.
  def running_game
    game = create_game(:is_draft => false)
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    game
  end

  it "is :scheduled for a published game that has not started" do
    expect(create_game(:is_draft => false).status).to eq(:scheduled)
  end

  it "is :scheduled for a published game with no start time at all" do
    game = create_game(:is_draft => false)
    set_game_schedule!(game, :starts_at => nil)

    expect(game.status).to eq(:scheduled)
  end

  it "is :running once the start time has passed" do
    expect(running_game.status).to eq(:running)
  end

  it "is :draft for a draft" do
    expect(create_game(:is_draft => true).status).to eq(:draft)
  end

  it "is :finished once the author has ended it" do
    game = running_game
    set_game_schedule!(game, :author_finished_at => Time.now)

    expect(game.status).to eq(:finished)
  end

  it "is :withdrawn for a withdrawn game" do
    game = create_game(:is_draft => false)
    game.withdraw!(:category => "other", :mode => "freeze")

    expect(game.status).to eq(:withdrawn)
  end

  # The predicates overlap by construction, so the ORDER is load-bearing.
  # These two pin it: without the precedence they would return :finished and
  # :draft respectively.
  it "reports :withdrawn for a game that is both withdrawn and finished" do
    game = running_game
    set_game_schedule!(game, :author_finished_at => Time.now)
    game.withdraw!(:category => "other", :mode => "freeze")

    expect(game.status).to eq(:withdrawn)
  end

  it "reports :draft for a draft whose start time has passed" do
    game = create_game(:is_draft => true)
    set_game_schedule!(game, :starts_at => 1.hour.ago)

    expect(game.status).to eq(:draft)
  end

  # Pausing and editing-locking are orthogonal: a game can be paused AND
  # running. Folding either into the precedence would hide one fact in order
  # to show the other -- the same reasoning count_by_status already documents
  # for locking.
  it "still reports :running for a paused game" do
    game = running_game
    game.pause!

    expect(game.status).to eq(:running)
  end

  it "still reports :running for an editing-locked game" do
    game = running_game
    game.lock_editing!

    expect(game.status).to eq(:running)
  end

  # The predicates overlap here too, and this is the pair the two `return`s
  # actually distinguish: SQL's count_by_status derives `live` (not
  # withdrawn) before it ever looks at is_draft, so a withdrawn draft can
  # only land in the :withdrawn bucket there -- but Ruby's #status is purely
  # positional, so swapping these two `return`s would make a withdrawn draft
  # report :draft while count_by_status still counts it as :withdrawn.
  it "reports :withdrawn for a draft that has also been withdrawn" do
    game = create_game(:is_draft => true)
    game.withdraw!(:category => "other", :mode => "freeze")

    expect(game.status).to eq(:withdrawn)
  end

  # THE guard the comment on count_by_status was standing in for. Two screens
  # disagreeing about what a game IS would be worse than either being wrong.
  it "agrees with count_by_status across every state" do
    create_game(:is_draft => true)
    create_game(:is_draft => false)
    running_game
    finished = running_game
    set_game_schedule!(finished, :author_finished_at => Time.now)
    create_game(:is_draft => false).withdraw!(:category => "other", :mode => "freeze")
    create_game(:is_draft => true).withdraw!(:category => "other", :mode => "freeze")

    tallied = Game.all.group_by(&:status).transform_values(&:size)
    tallied.default = 0
    counted = Game.count_by_status

    expect(counted[:withdrawn]).to eq(tallied[:withdrawn])
    expect(counted[:draft]).to     eq(tallied[:draft])
    expect(counted[:finished]).to  eq(tallied[:finished])
    expect(counted[:running]).to   eq(tallied[:running])
    expect(counted[:scheduled]).to eq(tallied[:scheduled])
  end
end
