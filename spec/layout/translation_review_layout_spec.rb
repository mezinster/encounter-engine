require "rails_helper"
require_relative "../support/layout_measurement"

# Translation review, measured. A flagged proposal must be identifiable by its
# edge in both layouts, the page must not scroll sideways, and on a phone each
# proposal must be a card. Excluded from the default run; LAYOUT_SPECS=1.
describe "the translation review table, measured", :layout, type: :request do
  include LayoutMeasurement

  let(:page_html) do
    allow(Translation::Client).to receive(:configured?).and_return(true)
    admin = create_user
    admin.update!(:is_superadmin => true)
    game  = create_game(:author => create_user, :is_draft => true, :primary_locale => "ru",
                        :available_locale_list => %w[ru en])
    level = create_level(:game => game, :name => "Первый",
                         :text => ("Найдите табличку на здании с часами. " * 12) +
                         " https://example.com/" + "a" * 200)
    run   = TranslationRun.create!(:game => game, :actor => admin, :model => "claude-opus-5",
                                   :state => TranslationRun::SUCCEEDED)
    TranslationProposal.create!(:translation_run => run, :translatable => level, :field => "text",
                                :locale => "en", :source_text => level.text,
                                :proposed_text => level.text, :flags => "identical,length",
                                :state => "pending")
    TranslationProposal.create!(:translation_run => run, :translatable => level, :field => "name",
                                :locale => "en", :source_text => "Первый", :proposed_text => "First",
                                :state => "pending")
    put login_path, :params => { :email => admin.email, :password => "1234" }
    get game_translation_run_proposals_path(game, run)
    expect(response).to have_http_status(:ok)
    response.body
  end

  def probe(theme)
    <<~JS
      document.documentElement.setAttribute("data-theme", "#{theme}");
      var probe = document.createElement("span");
      probe.style.color = "var(--danger)";
      document.body.appendChild(probe);
      var danger = getComputedStyle(probe).color;
      probe.remove();

      function edge(tr) {
        var s = getComputedStyle(tr);
        if (s.borderLeftWidth !== "0px" && s.borderLeftStyle !== "none") return s.borderLeftColor;
        var shadow = getComputedStyle(tr.cells[0]).boxShadow;
        return shadow === "none" ? "none" : shadow;
      }
      var flagged = Array.prototype.slice.call(document.querySelectorAll("table.proposals tbody tr.flagged"));
      var clean = Array.prototype.slice.call(document.querySelectorAll("table.proposals tbody tr:not(.flagged)"));
      var area = document.querySelector("table.proposals tbody tr.flagged textarea");
      var cell = area && area.closest("td");
      var RESULT = {
        theme: document.documentElement.getAttribute("data-theme"),
        flaggedCount: flagged.length,
        flaggedEdgesDanger: flagged.every(function (tr) { return edge(tr).indexOf(danger) !== -1; }),
        cleanEdgesDanger: clean.some(function (tr) { return edge(tr).indexOf(danger) !== -1; }),
        rowDisplays: flagged.concat(clean).map(function (tr) { return getComputedStyle(tr).display; }),
        textareaFills: !!cell && Math.abs(area.getBoundingClientRect().width -
          (cell.clientWidth - parseFloat(getComputedStyle(cell).paddingLeft) - parseFloat(getComputedStyle(cell).paddingRight))) < 2,
        firstCellShadow: flagged.length ? getComputedStyle(flagged[0].cells[0]).boxShadow : null,
        rowBorderLeft: flagged.length ? getComputedStyle(flagged[0]).borderLeftWidth : null,
        hOverflow: document.documentElement.scrollWidth - document.documentElement.clientWidth
      };
    JS
  end

  %w[dark light].each do |theme|
    { "phone" => [ 390, 680 ], "desktop" => [ 1280, 800 ] }.each do |name, (width, height)|
      context "#{theme} theme at #{width}x#{height} -- #{name}" do
        let(:m) { measure(page_html, width, height, probe(theme), :tmp_name => "translation-review-measure.html") }

        it "measured the theme it was asked for, with a flagged row present" do
          expect(m["theme"]).to eq(theme)
          expect(m["flaggedCount"]).to eq(1)
        end

        it "edges a flagged proposal in --danger and a clean one not" do
          expect(m["flaggedEdgesDanger"]).to be(true)
          expect(m["cleanEdgesDanger"]).to be(false)
        end

        it "fills the proposal cell with its textarea" do
          expect(m["textareaFills"]).to be(true)
        end

        it "does not scroll sideways" do
          expect(m["hOverflow"]).to eq(0), "hOverflow was #{m["hOverflow"]}"
        end

        if name == "phone"
          it "draws one edge per card, not two" do
            expect(m["firstCellShadow"]).to eq("none")
            expect(m["rowBorderLeft"]).to eq("3px")
          end

          it "stacks every proposal into a card" do
            expect(m["rowDisplays"].uniq).to eq(["block"])
          end
        end
      end
    end
  end
end
