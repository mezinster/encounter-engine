require "rails_helper"

describe "the results screen", type: :request do
  let(:author) { create_user }
  let(:game)   { g = create_game(:author => author); set_game_schedule!(g, :starts_at => 1.hour.ago); g }
  let!(:level) { create_level(:game => game) }

  it "refreshes the results table in place" do
    passing = create_game_passing(:level => level)
    passing.update_column(:finished_at, Time.now)
    put login_path, :params => { :email => author.email, :password => "1234" }

    get "/stats/show_results/#{game.id}"

    doc = Nokogiri::HTML(response.body)
    live = doc.at_css("[data-live]")
    expect(live["id"]).to eq("results-live")
    expect(live.at_css("table#results")).to be_present
    expect(doc.at_css("[data-live-status]")).to be_present
  end
end
