require "rails_helper"

# The full log and live channel, reworked for a phone. The ✓ must agree with
# the game's own scoring (Level#find_question_by_answer: strip + upcase, quiz
# questions skipped), never with a second rule written here.
describe "the operator's log screens", type: :request do
  let(:author) { create_user }
  let(:game) do
    g = create_game(:author => author, :is_draft => false)
    set_game_schedule!(g, :starts_at => 2.hours.ago)
    g
  end
  let(:team)  { create_team(:captain => create_user) }
  let(:quiet) { create_team(:captain => create_user) }
  let!(:level) { create_level(:game => game, :correct_answer => "Мост") }
  let(:doc) { Nokogiri::HTML(response.body) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def log(answer, who = team)
    create_log(:game => game, :level => level, :team => who, :game_run => game.current_run, :answer => answer)
  end

  def cell_for(name)
    doc.css("table.log-matrix td").find { |td| td.at_css(".log-team")&.text&.strip == name }
  end

  before do
    create_game_passing(:level => level, :team => team, :game_run => game.current_run)
    create_game_passing(:level => level, :team => quiet, :game_run => game.current_run)
    sign_in(author)
  end

  describe "the full log" do
    it "marks an answer the game would accept, including a case and whitespace variant" do
      log("  мост "); log("неверно")
      get show_full_log_path(:game_id => game.id)

      items = cell_for(team.name).css("li")
      accepted = items.select { |li| li.at_css(".log-ok") }.map { |li| li.text.gsub("✓", "").strip }
      expect(accepted.size).to eq(1)
      expect(accepted.first).to end_with("мост")
      expect(items.find { |li| li.text.include?("неверно") }.at_css(".log-ok")).to be_nil
      expect(cell_for(team.name).at_css(".log-ok")["aria-label"]).to eq("верно")
      expect(cell_for(team.name).at_css(".log-ok")["role"]).to eq("img")
    end

    it "does not mark a quiz level's leftover code the game refuses" do
      question = level.questions.first
      create_option(:question => question, :is_correct => true)
      log("Мост")
      get show_full_log_path(:game_id => game.id)

      expect(cell_for(team.name).at_css(".log-ok")).to be_nil
    end

    it "says a team has no answers on a level" do
      log("неверно")
      get show_full_log_path(:game_id => game.id)

      expect(cell_for(quiet.name).at_css(".log-none").text.strip).to eq("— нет ответов")
      expect(cell_for(quiet.name).at_css("ul")).to be_nil
    end

    it "keeps the title and puts the matrix in a live region" do
      get show_full_log_path(:game_id => game.id)

      expect(response.body).to include("Полный лог ответов")
      live = doc.at_css("[data-live]")
      expect(live["id"]).to eq("fulllog-live")
      expect(live.at_css("table#stats.log-matrix tr.log-level-row")).to be_present
      expect(doc.at_css("[data-live-status]")).to be_present
    end
  end

  describe "the live channel" do
    it "uses the compact card table inside a live region, cells classed for the phone layout" do
      log("мост")
      get show_live_channel_path(:game_id => game.id)

      live = doc.at_css("[data-live]")
      expect(live["id"]).to eq("livechannel-live")
      row = live.at_css("table#livechannel.table--cards.table--compact tbody tr")
      expect(row.css("td").map { |td| td["class"] }).to eq(%w[lc-time lc-team lc-level lc-code])
      expect(row.at_css(".lc-code").text.strip).to eq("мост")
      expect(doc.at_css("[data-live-status]")).to be_present
    end

    it "keeps the pager inside the live region, so a refresh replaces it with the rows" do
      51.times { |i| log("код#{i}") }
      get show_live_channel_path(:game_id => game.id)

      expect(doc.at_css("#livechannel-live .pager")).to be_present
    end
  end
end
