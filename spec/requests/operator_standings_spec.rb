require "rails_helper"

# The operator's standings screen (/stats/index/:game_id), reworked for a
# phone. Literal Russian, not I18n.t(...), which passes with a key missing.
describe "the operator's standings screen", type: :request do
  let(:author) { create_user }
  let(:game)   { g = create_game(:author => author); set_game_schedule!(g, :starts_at => 1.hour.ago); g }
  let!(:level) { create_level(:game => game) }
  let!(:playing)  { create_game_passing(:level => level) }
  let!(:finished) { p = create_game_passing(:level => level); p.update_column(:finished_at, Time.now); p }
  let(:doc) { Nokogiri::HTML(response.body) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def row_for(passing)
    doc.css("#stats tbody tr").find { |tr| tr.at_css(".standings-team").text.include?(passing.team.name) }
  end

  before { sign_in(author); get game_stats_path(game) }

  # features/logs/log.feature:29-61 clicks these on this page. They stay in
  # the row's markup; phones hide them with an external stylesheet rule only.
  it "keeps the frozen log links in the row, outside the panel" do
    row = row_for(playing)
    links = row.css("td.standings-log a").map { |a| a.text.strip }
    expect(links).to eq(["(лог по уровню)", "(лог по игре)"])
    expect(row.css("details a").map { |a| a.text.strip }).not_to include("(лог по уровню)", "(лог по игре)")
    expect(row.css("td.standings-log").map { |td| td["style"] }.compact).to be_empty
  end

  it "opens with full-size log buttons in the intervention panel" do
    panel = row_for(playing).at_css("details .team-panel-actions")
    buttons = panel.css("a.btn").map { |a| [a.text.strip, a["href"]] }
    expect(buttons).to include(["Лог уровня", show_level_log_path(:game_id => game.id, :team_id => playing.team_id)])
    expect(buttons).to include(["Лог игры", show_game_log_path(:game_id => game.id, :team_id => playing.team_id)])
  end

  it "offers no level-log button for a team that has finished, as the row offers no link" do
    labels = row_for(finished).css("details .team-panel-actions a.btn").map { |a| a.text.strip }
    expect(labels).to include("Лог игры")
    expect(labels).not_to include("Лог уровня")
  end

  it "puts pause and the live status in the control bar after the table" do
    ops = doc.at_css(".ops")
    children = ops.element_children.map { |e| e["class"].to_s.split.first || e.name }
    expect(children).to eq(["table-wrap", "ops-full-log", "opbar"])
    bar = ops.at_css(".opbar")
    expect(bar.at_css("button").text.strip).to eq("Приостановить игру")
    expect(bar.at_css("[data-live-status]")).to be_present
  end

  it "marks only the table as the live region" do
    live = doc.css("[data-live]")
    expect(live.size).to eq(1)
    expect(live.first["id"]).to eq("standings-live")
    expect(live.first.at_css("table#stats.table--cards.table--compact.standings")).to be_present
    expect(live.first.at_css(".opbar")).to be_nil
  end

  it "shows the paused state and the resume button in the bar" do
    set_game_schedule!(game, :paused_at => 5.minutes.ago)
    get game_stats_path(game)
    bar = doc.at_css(".opbar")
    expect(bar.text).to include("Игра приостановлена в")
    expect(bar.at_css("button").text.strip).to eq("Продолжить игру")
  end
end
