require "rails_helper"

describe Game do
  it "is neither locked nor withdrawn by default" do
    game = create_game
    expect(game.editing_locked?).to be false
    expect(game.withdrawn?).to be false
  end

  it "reports an editing lock once the timestamp is set" do
    game = create_game
    game.update!(:editing_locked_at => Time.now)
    expect(game.reload.editing_locked?).to be true
  end

  it "reports withdrawal once the timestamp is set" do
    game = create_game
    game.update!(:withdrawn_at => Time.now)
    expect(game.reload.withdrawn?).to be true
  end
end
