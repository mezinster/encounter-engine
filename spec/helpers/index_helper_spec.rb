require "rails_helper"

describe IndexHelper, type: :helper do
  let(:game) { create_game }

  def entry(status)
    create_game_entry(:game => game, :team => create_team(:captain => create_user), :status => status)
  end

  describe "#home_registration_open?" do
    it "is open for a scheduled game under its limit with no deadline" do
      expect(helper.home_registration_open?(game)).to be(true)
    end

    it "is closed once the deadline has passed" do
      set_game_schedule!(game, :registration_deadline => 1.hour.ago, :starts_at => 1.day.from_now)
      expect(helper.home_registration_open?(game)).to be(false)
    end

    it "is closed once the game has started" do
      set_game_schedule!(game, :starts_at => 1.hour.ago)
      expect(helper.home_registration_open?(game.reload)).to be(false)
    end
  end

  describe "#home_status_tag" do
    it "says a running game is happening now" do
      set_game_schedule!(game, :starts_at => 1.hour.ago)
      expect(helper.home_status_tag(game.reload)).to eq(["Идёт сейчас", "tag tag--live"])
    end

    it "shows the registration tag when there is no entry" do
      expect(helper.home_status_tag(game)).to eq(["Регистрация открыта", "tag tag--live"])
    end

    it "shows a pending application" do
      expect(helper.home_status_tag(game, :entry => entry("new"))).to eq(["Заявка подана", "tag"])
    end

    it "shows an accepted application" do
      expect(helper.home_status_tag(game, :entry => entry("accepted"))).to eq(["Вы зарегистрированы", "tag tag--live"])
    end

    it "shows a rejected application in danger" do
      expect(helper.home_status_tag(game, :entry => entry("rejected"))).to eq(["Заявка отклонена", "tag tag--danger"])
    end

    it "treats a recalled or cancelled entry as no entry" do
      %w[recalled canceled].each do |status|
        expect(helper.home_status_tag(game, :entry => entry(status))).to eq(["Регистрация открыта", "tag tag--live"])
      end
    end

    it "labels a code-gated game, live or not" do
      gated = create_game(:access_mode => "pass_required")
      expect(helper.home_status_tag(gated)).to eq(["По коду доступа", "tag"])
      expect(helper.home_status_tag(gated, :gated_live => true)).to eq(["Доступ есть", "tag tag--live"])
    end
  end
end
