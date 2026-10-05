require "rails_helper"
require_relative "../support/layout_measurement"

# The game page's facts panel and the operator's button row, measured in a real
# browser in both themes. Excluded from the default run (needs
# chrome-headless-shell); LAYOUT_SPECS=1. A missing browser raises.
#
# The separators are the reason this file exists. The " - " and colons stay in
# the markup for the frozen features and only screens.css hides them, so if that
# rule is lost every suite stays green while people read «Автор - Evgeny» again.
describe "the game page's facts panel, measured", :layout, type: :request do
  include LayoutMeasurement

  def page_html
    author = create_user
    operator = create_user
    operator.update!(:is_operator => true)
    game = create_game(:author => author, :max_team_number => 5,
                       :description => "Оченьдлинноеслово" * 8 + "\nВторая строка описания.")
    game.update!(:access_mode => "pass_required")
    set_game_schedule!(game, :starts_at => 2.days.from_now, :registration_deadline => 1.day.from_now)
    put login_path, :params => { :email => operator.email, :password => "1234" }
    get game_path(game)
    expect(response).to have_http_status(:ok)
    response.body
  end

  def probe(theme)
    <<~JS
      document.documentElement.setAttribute("data-theme", "#{theme}");
      var seps = Array.prototype.slice.call(document.querySelectorAll(".game-facts .fact-sep"));
      var labels = Array.prototype.slice.call(document.querySelectorAll(".game-facts .fact-label"));
      var facts = Array.prototype.slice.call(document.querySelectorAll(".facts > .fact"));
      var row = document.querySelector(".game-control a[href$='/access_passes']").parentElement;
      var btns = Array.prototype.slice.call(row.querySelectorAll("a.btn"));
      var value = document.querySelector(".fact--max-teams .fact-value");
      var RESULT = {
        sepCount: seps.length,
        sepsShown: seps.filter(function (el) { return getComputedStyle(el).display !== "none"; }).length,
        labelCount: labels.length,
        italicLabels: labels.filter(function (el) { return getComputedStyle(el).fontStyle !== "normal"; }).length,
        labelsDim: labels.every(function (el) { return getComputedStyle(el).color !== getComputedStyle(value).color; }),
        firstRowTiles: facts.filter(function (el) { return Math.abs(el.getBoundingClientRect().top - facts[0].getBoundingClientRect().top) < 1; }).length,
        buttonCount: btns.length,
        buttonsOneRow: btns.length === 2 && Math.abs(btns[0].getBoundingClientRect().top - btns[1].getBoundingClientRect().top) < 1,
        hOverflow: document.documentElement.scrollWidth - document.documentElement.clientWidth
      };
    JS
  end

  %w[dark light].each do |theme|
    { "phone" => [ 390, 680 ], "desktop" => [ 1280, 800 ] }.each do |name, (width, height)|
      context "#{theme} theme at #{width}x#{height} -- #{name}" do
        let(:m) { measure(page_html, width, height, probe(theme), :tmp_name => "game-facts-measure.html") }

        it "hides every separator the frozen features read, and only by stylesheet" do
          expect(m["sepCount"]).to eq(5)
          expect(m["sepsShown"]).to eq(0)
        end

        it "sets labels apart from values: upright, and dimmer" do
          expect(m["labelCount"]).to eq(5)
          expect(m["italicLabels"]).to eq(0)
          expect(m["labelsDim"]).to be(true)
        end

        it "does not scroll sideways, even on an unbroken description" do
          expect(m["hOverflow"]).to be <= 0
        end

        if name == "desktop"
          it "lays the facts out as tiles, several to a row" do
            expect(m["firstRowTiles"]).to be >= 3
          end

          it "puts the pass and code buttons side by side" do
            expect(m["buttonCount"]).to eq(2)
            expect(m["buttonsOneRow"]).to be(true)
          end
        end
      end
    end
  end
end
