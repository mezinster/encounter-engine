require "rails_helper"

describe "choosing how a level's codes count", type: :request do
  let(:author) { create_user }
  let(:game)   { create_game(:author => author) }
  let(:level)  { create_level(:game => game) }

  before { put login_path, :params => { :email => author.email, :password => "1234" } }

  it "offers the choice on the new-level form" do
    get new_game_level_path(game)

    expect(response.body).to include(I18n.t("levels.form.codes_rule"))
    expect(response.body).to include(I18n.t("levels.codes_rule_any"))
    expect(response.body).to include(I18n.t("levels.codes_rule_all"))
  end

  it "offers the choice on the edit form" do
    get edit_game_level_path(game, level)

    expect(response.body).to include(I18n.t("levels.form.codes_rule"))
  end

  it "saves the choice" do
    expect(level.any_code_passes).to be true

    patch game_level_path(game, level),
          :params => { :level => { :name => level.name, :text => level.text, :any_code_passes => "0" } }

    expect(level.reload.any_code_passes).to be false
  end

  # The change that actually closes the trap: a list of three codes says
  # nothing about how they combine, and the author only discovers the rule
  # during play.
  describe "the level page states the rule" do
    it "says so when any code passes" do
      get game_level_path(game, level)

      expect(response.body).to include(I18n.t("levels.codes_rule_any"))
    end

    it "says so when all codes are required" do
      level.update_column(:any_code_passes, false)

      get game_level_path(game, level)

      expect(response.body).to include(I18n.t("levels.codes_rule_all"))
    end

    # Rendered on a one-code level too, where both modes behave identically.
    # Suppressing it there would mean the line first appears only after a
    # second code is added -- the moment the author has already decided blind.
    it "states the rule even on a single-code level" do
      get game_level_path(game, level)

      expect(level).not_to be_multi_question
      expect(response.body).to include(I18n.t("levels.codes_rule_any"))
    end
  end
end
