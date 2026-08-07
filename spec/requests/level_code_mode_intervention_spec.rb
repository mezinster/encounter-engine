require "rails_helper"

describe "an operator changing how a level's codes count mid-game", type: :request do
  let(:author)     { create_user }
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:game)       { create_game(:author => author) }
  let(:level)      { create_level(:game => game) }

  before do
    level
    game.update_column(:starts_at, 1.hour.ago)
  end

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "lets a superadmin require all codes on a live game" do
    level.update_column(:any_code_passes, true)
    sign_in(superadmin)

    post require_all_codes_level_path(:game_id => game.id, :id => level.id)

    expect(level.reload.any_code_passes).to be false
  end

  it "lets a superadmin allow any code on a live game" do
    level.update_column(:any_code_passes, false)
    sign_in(superadmin)

    post allow_any_code_level_path(:game_id => game.id, :id => level.id)

    expect(level.reload.any_code_passes).to be true
  end

  # Deliberately narrower than every other action in this controller, which use
  # ensure_author (meaning "the author, or any superadmin"). This one changes
  # the difficulty of a race already in progress, for every team at once, after
  # some have committed effort to the harder rule.
  it "refuses the game's own author" do
    level.update_column(:any_code_passes, false)
    sign_in(author)

    post allow_any_code_level_path(:game_id => game.id, :id => level.id)

    expect(response).to have_http_status(:unauthorized)
    expect(level.reload.any_code_passes).to be false
  end

  it "refuses an unrelated user" do
    sign_in(create_user)

    post allow_any_code_level_path(:game_id => game.id, :id => level.id)

    expect(response).to have_http_status(:unauthorized)
  end

  describe "the audit trail" do
    it "records the action against the level" do
      sign_in(superadmin)

      expect { post allow_any_code_level_path(:game_id => game.id, :id => level.id) }
        .to change { AdminAction.count }.by(1)

      entry = AdminAction.newest_first.first
      expect(entry.action).to eq("allow_any_code")
      expect(entry.target_type).to eq("Level")
      expect(entry.target_label).to eq(level.name)
    end

    # The case the controller's own audit() helper would silently skip: it is
    # gated by acting_as_operator?, which is false when the superadmin owns the
    # game. This action is superadmin-only, so that is exactly the case an
    # audit trail exists for -- actor and beneficiary being the same person.
    it "records a superadmin acting on their own game" do
      own = create_game(:author => superadmin)
      own_level = create_level(:game => own)
      own.update_column(:starts_at, 1.hour.ago)
      sign_in(superadmin)

      expect { post allow_any_code_level_path(:game_id => own.id, :id => own_level.id) }
        .to change { AdminAction.count }.by(1)
    end
  end

  it "refuses to require all codes on a level with no codes" do
    level.questions.destroy_all
    sign_in(superadmin)

    post require_all_codes_level_path(:game_id => game.id, :id => level.reload.id)

    # InterventionsController#refused redirects with :alert, not :notice.
    expect(response).to redirect_to(game_stats_path(game))
    expect(flash[:alert]).to eq(I18n.t("interventions.refused"))
    expect(level.reload.any_code_passes).to be true
  end
end
