require "rails_helper"

# LevelsController#find_level used to be Level.find(params[:id]) -- unscoped,
# while ensure_author/ensure_game_was_not_started only ever check @game, which
# comes from params[:game_id]. That let a request pair its OWN (authorized)
# game_id with someone else's level_id and pass every filter: verified over
# HTTP by the whole-branch review (finding 1) -- a non-author, non-superadmin
# user paired her own draft game's id with another author's live level's id
# and successfully flipped :any_code_passes on it, then renamed it, with no
# audit row written either time. See app/controllers/levels_controller.rb's
# find_level for the fix (scoped through @game.levels, matching
# InterventionsController's find_level).
describe "a non-author reaching another game's level through LevelsController", type: :request do
  let(:victim_author) { create_user }
  let(:victim_game)    { create_game(:author => victim_author) }
  let(:victim_level)   { create_level(:game => victim_game) }

  let(:attacker)     { create_user }
  let(:attacker_game) { create_game(:author => attacker) }

  before do
    victim_level
    attacker_game
    put login_path, :params => { :email => attacker.email, :password => "1234" }
  end

  it "404s on show" do
    expect { get game_level_path(attacker_game, victim_level) }
      .to raise_error(ActiveRecord::RecordNotFound)
  end

  it "404s on edit" do
    expect { get edit_game_level_path(attacker_game, victim_level) }
      .to raise_error(ActiveRecord::RecordNotFound)
  end

  it "404s on update and does not change the victim level" do
    expect {
      expect {
        patch game_level_path(attacker_game, victim_level),
              :params => { :level => { :name => "ВЗЛОМАНО", :any_code_passes => "0" } }
      }.to raise_error(ActiveRecord::RecordNotFound)
    }.not_to change { victim_level.reload.attributes }
  end

  it "404s on delete and does not destroy the victim level" do
    expect {
      expect { get delete_game_level_path(attacker_game, victim_level) }
        .to raise_error(ActiveRecord::RecordNotFound)
    }.not_to change { Level.exists?(victim_level.id) }
  end

  it "404s on move_up" do
    expect { get move_up_game_level_path(attacker_game, victim_level) }
      .to raise_error(ActiveRecord::RecordNotFound)
  end

  it "404s on move_down" do
    expect { get move_down_game_level_path(attacker_game, victim_level) }
      .to raise_error(ActiveRecord::RecordNotFound)
  end
end
