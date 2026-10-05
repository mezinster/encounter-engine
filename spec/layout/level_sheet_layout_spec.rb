require "rails_helper"
require_relative "../support/layout_measurement"

# The author's level page as a sectioned sheet, measured in a real browser in
# both themes. Excluded from the default run (needs chrome-headless-shell);
# LAYOUT_SPECS=1. A missing browser raises.
#
# The colons the frozen features read ("Коды (2):") stay in the markup and only
# screens.css hides them, so losing that rule leaves every suite green while
# people read the colons again -- the same seam as the game page's facts panel.
describe "the author's level page, measured", :layout, type: :request do
  include LayoutMeasurement

  def page_html
    author = create_user
    game = create_game(:author => author, :name => "Сокровище нации")
    level = create_level(:game => game, :name => "Сокровищница", :correct_answer => "tr1122",
                         :text => "Найдите табличку у входа.\nВторая строка задания.")
    create_question(:level => level, :correct_answer => "оченьдлинныйкодбезпробелов" * 3)
    create_hint(:level => level, :text => "Ищите у фонтана", :delay => 600)
    create_hint(:level => level, :text => "Колонны считайте только с фасада", :delay => 1200)
    put login_path, :params => { :email => author.email, :password => "1234" }
    get game_level_path(game, level)
    expect(response).to have_http_status(:ok)
    response.body
  end

  def probe(theme)
    <<~JS
      document.documentElement.setAttribute("data-theme", "#{theme}");
      var seps = Array.prototype.slice.call(document.querySelectorAll(".level-sheet .fact-sep, .hints-card .fact-sep"));
      var labels = Array.prototype.slice.call(document.querySelectorAll(".level-sheet .fact-label"));
      var text = document.querySelector(".level-text");
      var buttons = Array.prototype.slice.call(document.querySelectorAll(".level-sheet .btn, .hints-card .btn, .danger-row .btn"));
      var rows = Array.prototype.slice.call(document.querySelectorAll(".code-row"));
      var RESULT = {
        sepCount: seps.length,
        sepsShown: seps.filter(function (el) { return getComputedStyle(el).display !== "none"; }).length,
        labelCount: labels.length,
        italicLabels: labels.filter(function (el) { return getComputedStyle(el).fontStyle !== "normal"; }).length,
        labelsDim: labels.every(function (el) { return getComputedStyle(el).color !== getComputedStyle(text).color; }),
        buttonCount: buttons.length,
        shortButtons: buttons.filter(function (el) { return el.getBoundingClientRect().height < 43.5; })
                             .map(function (el) { return el.textContent.trim(); }),
        rowCount: rows.length,
        deleteBesideCode: rows.every(function (row) {
          var chip = row.querySelector(".code-chip").getBoundingClientRect();
          var del = row.querySelector(".btn--danger").getBoundingClientRect();
          return del.top < chip.bottom && del.bottom > chip.top;
        }),
        hOverflow: document.documentElement.scrollWidth - document.documentElement.clientWidth
      };
    JS
  end

  %w[dark light].each do |theme|
    { "phone" => [ 390, 680 ], "desktop" => [ 1280, 800 ] }.each do |name, (width, height)|
      context "#{theme} theme at #{width}x#{height} -- #{name}" do
        let(:m) { measure(page_html, width, height, probe(theme), :tmp_name => "level-sheet-measure.html") }

        it "hides every separator the frozen features read, and only by stylesheet" do
          expect(m["sepCount"]).to eq(3)
          expect(m["sepsShown"]).to eq(0)
        end

        it "sets section labels apart from content: upright, and dimmer" do
          expect(m["labelCount"]).to eq(2)
          expect(m["italicLabels"]).to eq(0)
          expect(m["labelsDim"]).to be(true)
        end

        it "makes every button a full-size tap target" do
          expect(m["buttonCount"]).to be >= 8
          expect(m["shortButtons"]).to eq([])
        end

        it "does not scroll sideways, even on an unbroken code" do
          expect(m["hOverflow"]).to be <= 0
        end

        if name == "desktop"
          it "keeps each code's delete button on that code's row" do
            expect(m["rowCount"]).to eq(2)
            expect(m["deleteBesideCode"]).to be(true)
          end
        end
      end
    end
  end
end
