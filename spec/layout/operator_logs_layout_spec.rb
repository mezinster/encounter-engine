require "rails_helper"
require_relative "../support/layout_measurement"

# The operator's log screens and the overflow-only pages, measured in a real
# browser in both themes at phone and desktop width. One running game, eight
# levels, twelve teams (one with a long unbroken name) and about sixty log rows
# carrying a long unbroken answer and level name. Excluded from the default run
# (needs chrome-headless-shell); LAYOUT_SPECS=1. A missing browser raises.
describe "the operator log screens, measured", :layout, type: :request do
  include LayoutMeasurement

  LONG_ANSWER = "Оченьдлинныйответбезпробеловкоторыйнедолженрасширятьэкран"
  LONG_LEVEL  = "Оченьдлинноеназваниеуровнябезпробелов"
  LONG_TEAM   = "Оченьдлинноеназваниекомандыбезпробеловкотороенедолжнорасширятьстраницу"

  def build_world
    author = create_user
    game = create_game(:author => author)
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    levels = (1..8).map do |i|
      create_level(:game => game, :name => (i == 3 ? LONG_LEVEL : "Уровень #{i}"), :correct_answer => "код#{i}")
    end
    teams = (1..12).map do |i|
      team = create_team(:captain => create_user)
      team.update!(:name => LONG_TEAM) if i == 1
      create_game_passing(:level => levels[i % 8], :team => team, :game_run => game.current_run)
      team
    end
    60.times do |i|
      create_log(:game => game, :level => levels[i % 8], :team => teams[i % 12],
                 :game_run => game.current_run, :time => i.minutes.ago,
                 :answer => (i % 5 == 0 ? LONG_ANSWER : "ответ#{i}"))
    end
    { :author => author, :game => game, :long_team => teams.first }
  end

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  PAGES = %w[full\ log live\ channel level\ log game\ log game\ page entries].freeze

  # Built per example, because the route helpers exist on the example, not on
  # the example group.
  def path_for(page, w)
    case page
    when "full log"     then show_full_log_path(:game_id => w[:game].id)
    when "live channel" then show_live_channel_path(:game_id => w[:game].id)
    when "level log"    then show_level_log_path(:game_id => w[:game].id, :team_id => w[:long_team].id)
    when "game log"     then show_game_log_path(:game_id => w[:game].id, :team_id => w[:long_team].id)
    when "game page"    then game_path(w[:game])
    when "entries"      then admin_game_entries_path(:game_id => w[:game].id)
    end
  end

  def page_html(page)
    world = build_world
    if page == "entries"
      admin = create_user
      admin.update!(:is_superadmin => true)
      sign_in(admin)
    else
      sign_in(world[:author])
    end
    get path_for(page, world)
    expect(response).to have_http_status(:ok)
    response.body
  end

  def probe(theme)
    <<~JS
      document.documentElement.setAttribute("data-theme", "#{theme}");
      var vw = document.documentElement.clientWidth;
      var scrollers = Array.prototype.slice.call(document.querySelectorAll("body *")).filter(function (el) {
        var s = getComputedStyle(el); return (s.overflowX === "auto" || s.overflowX === "scroll") && el.scrollWidth > el.clientWidth + 1; });
      var teamCells = Array.prototype.slice.call(document.querySelectorAll("table.log-matrix tr:not(.log-level-row) td"));
      var firstTeamRow = document.querySelector("table.log-matrix tr:not(.log-level-row)");
      var RESULT = {
        theme: document.documentElement.getAttribute("data-theme"),
        hOverflow: document.documentElement.scrollWidth - vw,
        innerScrollers: scrollers.map(function (el) { return (el.id || el.className || el.tagName) + ":" + el.scrollWidth + "/" + el.clientWidth; }),
        narrowTeamCells: teamCells.filter(function (td) { return td.getBoundingClientRect().width < vw * 0.8; }).length,
        teamCellCount: teamCells.length,
        desktopGridCells: firstTeamRow ? Array.prototype.slice.call(firstTeamRow.children).filter(function (td) { return getComputedStyle(td).display === "table-cell"; }).length : 0
      };
    JS
  end

  PAGES.each do |page|
    %w[dark light].each do |theme|
      { "phone" => [ 390, 680 ], "desktop" => [ 1280, 800 ] }.each do |name, (width, height)|
        context "#{page}, #{theme} theme at #{width}x#{height} -- #{name}" do
          let(:m) { measure(page_html(page), width, height, probe(theme), :tmp_name => "operator-logs-measure.html") }

          it "measured the theme it was asked for" do
            expect(m["theme"]).to eq(theme)
          end

          it "does not scroll sideways at the page level" do
            expect(m["hOverflow"]).to eq(0)
          end

          if name == "phone"
            it "has no inner sideways scroller" do
              expect(m["innerScrollers"]).to eq([])
            end

            if page == "full log"
              it "gives every team block the full width" do
                expect(m["teamCellCount"]).to be > 0
                expect(m["narrowTeamCells"]).to eq(0)
              end
            end
          elsif page == "full log"
            it "is still a grid" do
              expect(m["desktopGridCells"]).to be > 1
            end
          end
        end
      end
    end
  end
end
