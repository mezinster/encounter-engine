# -*- encoding : utf-8 -*-
require "rails_helper"

# The single writer of author_id after creation, mirroring Team#set_captain!.
# See docs/superpowers/specs/2026-08-10-quest-mode-and-authorship-design.md.
RSpec.describe Game, "#transfer_authorship_to!" do
  let(:author)    { create_user }
  let(:successor) { create_user }
  let(:game)      { create_game(:author => author) }

  it "moves author_id to the new author" do
    game.transfer_authorship_to!(successor)

    expect(game.reload.author_id).to eq(successor.id)
  end

  it "leaves the in-memory record agreeing with the row" do
    game.transfer_authorship_to!(successor)

    expect(game.author).to eq(successor)
  end

  it "turns author_of? over for both users" do
    game.transfer_authorship_to!(successor)
    game.reload

    expect(author.author_of?(game)).to be false
    expect(successor.author_of?(game)).to be true
  end

  it "refuses nil rather than orphaning the game" do
    expect { game.transfer_authorship_to!(nil) }.to raise_error(ArgumentError)
  end

  # THE trap. The superadmin path has no lifecycle refusals, so this method is
  # reached on running games -- and a running game fails its own validations,
  # because game_starts_in_the_future adds an error whenever starts_at is past
  # and author_finished_at is nil. update! would raise RecordInvalid on exactly
  # the games the operator path exists for.
  #
  # This is the bug withdraw!, restore!, unfinish!, lock_editing! and
  # unlock_editing! all shipped with. Their specs stayed green because
  # create_game defaults starts_at to 2099, so no example had ever exercised a
  # started game. This one does, deliberately.
  it "transfers a game that has already started" do
    running = create_game(:author => author, :starts_at => 1.minute.from_now)
    allow(Time).to receive(:now).and_return(1.hour.from_now)

    expect { running.transfer_authorship_to!(successor) }.not_to raise_error
    expect(running.reload.author_id).to eq(successor.id)
  end
end
