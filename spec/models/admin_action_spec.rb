# spec/models/admin_action_spec.rb
require "rails_helper"

describe AdminAction do
  let(:actor) { u = create_user; u.update!(:is_superadmin => true); u }

  describe ".label_for" do
    it "uses a game's name" do
      game = create_game(:name => "Городской квест")
      expect(AdminAction.label_for(game)).to eq("Городской квест")
    end

    it "uses a user's nickname" do
      user = create_user
      expect(AdminAction.label_for(user)).to eq(user.nickname)
    end

    it "is nil for no target" do
      expect(AdminAction.label_for(nil)).to be_nil
    end
  end

  # The property the column exists for. A deleted game leaves target_id
  # pointing at nothing, so without the snapshot the single most important
  # entry an audit trail holds -- who deleted what -- reads as "Game #47".
  it "still names its target after the target is destroyed" do
    game = create_game(:name => "Обречённая игра", :is_draft => true)
    entry = AdminAction.create!(:actor_id => actor.id, :action => "delete",
                                :target_type => "Game", :target_id => game.id,
                                :target_label => AdminAction.label_for(game))
    game.destroy

    expect(Game.where(:id => entry.target_id)).to be_empty
    expect(entry.reload.target_label).to eq("Обречённая игра")
  end

  it "orders newest first" do
    older = AdminAction.create!(:actor_id => actor.id, :action => "lock")
    newer = AdminAction.create!(:actor_id => actor.id, :action => "unlock")
    older.update_column(:created_at, 1.hour.ago)

    expect(AdminAction.newest_first.first).to eq(newer)
  end
end
