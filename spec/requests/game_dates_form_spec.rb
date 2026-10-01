require "rails_helper"

# The game form's dates are native datetime-local inputs. The server is
# unchanged; what these pin is the form and the one browser behaviour the
# frozen scenarios cannot send -- a T-separated value.
describe "the game form's date fields", type: :request do
  let(:author) { u = create_user; u.update!(:timezone => "Asia/Bishkek"); u }
  let(:doc) { Nokogiri::HTML(response.body) }

  before { put login_path, :params => { :email => author.email, :password => "1234" } }

  shared_examples "a form with native date fields" do
    it "renders both dates as datetime-local inputs" do
      expect(doc.at_css("input#game_starts_at")["type"]).to eq("datetime-local")
      expect(doc.at_css("input#game_registration_deadline")["type"]).to eq("datetime-local")
    end

    it "names the author's timezone and links to where it is set" do
      hints = doc.css("p.notice.timezone-hint")
      expect(hints.size).to eq(2)
      expect(hints.first.text).to include("Asia/Bishkek (UTC+06:00)")
      expect(hints.first.at_css("a")["href"]).to eq(edit_user_path(author))
    end

    it "loads no calendar script or stylesheet" do
      expect(response.body).not_to match(/calendar(-setup|-ru-UTF)?\.js|calendar\.css|Calendar\.setup/)
    end
  end

  context "on the new-game form" do
    before { get new_game_path }
    include_examples "a form with native date fields"
  end

  context "on the edit form" do
    let(:game) { create_game(:author => author) }
    before do
      Time.use_zone("Asia/Bishkek") { game.update!(:starts_at => Time.zone.parse("2050-03-21 18:01")) }
      get edit_game_path(game)
    end
    include_examples "a form with native date fields"

    it "prefills the start in the author's zone, to the minute" do
      expect(doc.at_css("input#game_starts_at")["value"]).to eq("2050-03-21T18:01")
    end
  end

  it "accepts the T-separated value a browser sends, in the author's zone" do
    post games_path, :params => { :game => { :name => "Ночной город", :description => "Старт у ЦУМа",
                                             :starts_at => "2050-03-21T18:01", :max_team_number => "2" } }
    follow_redirect!

    expect(response.body).to include("2050-03-21 18:01")
    game = Game.find_by!(:name => "Ночной город")
    expect(game.starts_at.in_time_zone("Asia/Bishkek").strftime("%Y-%m-%d %H:%M")).to eq("2050-03-21 18:01")
  end
end
