require "rails_helper"
require_relative "../support/layout_measurement"

# The operator's log screens and the overflow-only pages, measured in a real
# browser in both themes at phone and desktop width. One running game, eight
# levels, twelve teams (one with a long unbroken name) and about sixty log rows
# carrying a long unbroken answer and level name. Excluded from the default run
# (needs chrome-headless-shell); LAYOUT_SPECS=1. A missing browser raises.
describe "the operator log screens, measured", :layout, type: :request do
  include LayoutMeasurement

  let(:long_answer) { "Оченьдлинныйответбезпробеловкоторыйнедолженрасширятьэкран" }
  let(:long_level)  { "Оченьдлинноеназваниеуровнябезпробелов" }
  let(:long_team)   { "Оченьдлинноеназваниекомандыбезпробеловкотороенедолжнорасширятьстраницу" }

  def build_world
    author = create_user
    game = create_game(:author => author)
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    levels = (1..8).map do |i|
      create_level(:game => game, :name => (i == 3 ? long_level : "Уровень #{i}"), :correct_answer => "код#{i}")
    end
    teams = (1..12).map do |i|
      team = create_team(:captain => create_user)
      team.update!(:name => long_team) if i == 1
      # The long team sits on the long-named level (index 2), the level
      # show_level_log is keyed to.
      create_game_passing(:level => levels[i == 1 ? 2 : i % 8], :team => team, :game_run => game.current_run)
      # Entries for the admin console: it lists "new" and "accepted" ones.
      create_game_entry(:game => game, :team => team, :status => (i.odd? ? "new" : "accepted"))
      team
    end
    60.times do |i|
      create_log(:game => game, :level => levels[i % 8], :team => teams[i % 12],
                 :game_run => game.current_run, :time => i.minutes.ago,
                 :answer => (i % 5 == 0 ? long_answer : "ответ#{i}"))
    end
    # Several rows for the long team: three on its current (long-named) level
    # with the long answer, others elsewhere for the game log.
    3.times do |i|
      create_log(:game => game, :level => levels[2], :team => teams.first,
                 :game_run => game.current_run, :time => (100 + i).minutes.ago, :answer => long_answer)
    end
    [0, 1, 4].each do |l|
      create_log(:game => game, :level => levels[l], :team => teams.first,
                 :game_run => game.current_run, :time => (200 + l).minutes.ago, :answer => "ответ#{l}")
    end
    { :author => author, :game => game, :long_team => teams.first }
  end

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  pages = ["full log", "live channel", "level log", "game log", "game page", "entries"]

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

  def expected_strings(page)
    case page
    when "full log"     then [long_team, long_answer]
    when "live channel" then [long_answer]
    when "level log"    then [long_level, long_answer]
    when "game log"     then [long_answer]
    when "game page"    then [long_team, long_level]
    when "entries"      then [long_team]
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
    # Guard against a vacuous pass: the long strings this page is meant to
    # exercise must really be in the markup before anything is measured.
    expected_strings(page).each { |str| expect(response.body).to include(str) }
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

  pages.each do |page|
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
