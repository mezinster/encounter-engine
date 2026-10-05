require "rails_helper"
require_relative "../support/layout_measurement"

# The superadmin console, measured in a real browser in both themes. Excluded
# from the default run (needs chrome-headless-shell); LAYOUT_SPECS=1. A missing
# browser raises. Tasks 8 and 11 of the 2026-10-05 plan add the games list,
# the game page, the user page and the teams list to this file.
describe "the superadmin console, measured", :layout, type: :request do
  include LayoutMeasurement

  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }

  def superadmin_html(path)
    put login_path, :params => { :email => superadmin.email, :password => "1234" }
    get path
    expect(response).to have_http_status(:ok)
    response.body
  end

  def measure_admin(html, width, height, theme, body)
    measure(html, width, height, <<~JS, :tmp_name => "admin-console-measure.html")
      document.documentElement.setAttribute("data-theme", "#{theme}");
      var vw = document.documentElement.clientWidth;
      #{body}
    JS
  end

  TABS_PROBE = <<~JS
    var links = Array.prototype.slice.call(document.querySelectorAll(".admin-tabs a"));
    var RESULT = {
      count: links.length,
      clipped: links.filter(function (a) { var r = a.getBoundingClientRect(); return r.left < 0 || r.right > vw; }).map(function (a) { return a.textContent; }),
      barScrolls: (function (n) { return n.scrollWidth > n.clientWidth + 1; })(document.querySelector(".admin-tabs")),
      shortTabs: links.filter(function (a) { return a.getBoundingClientRect().height < 43.5; }).map(function (a) { return a.textContent; }),
      hOverflow: document.documentElement.scrollWidth - vw
    };
  JS

  %w[dark light].each do |theme|
    { "phone" => [ 390, 680 ], "laptop" => [ 845, 700 ], "desktop" => [ 1280, 800 ] }.each do |name, (width, height)|
      context "tabs, #{theme} theme at #{width}x#{height} -- #{name}" do
        let(:m) { measure_admin(superadmin_html(admin_dashboard_path), width, height, theme, TABS_PROBE) }

        # Wrapping is allowed; hiding is not. A bar that scrolled sideways hid
        # half the tabs at 845-1024px, where this console is mostly used.
        it "shows all eight tabs, full-size, none clipped, without widening the page" do
          expect(m["count"]).to eq(8)
          expect(m["clipped"]).to eq([])
          expect(m["barScrolls"]).to be(false)
          expect(m["shortTabs"]).to eq([])
          expect(m["hOverflow"]).to be <= 0
        end
      end
    end
  end

  GAME_PAGE_PROBE = <<~JS
    var controls = Array.prototype.slice.call(document.querySelectorAll(".admin-game .btn, .admin-game input:not([type=hidden]), .admin-game button"));
    var RESULT = {
      count: controls.length,
      short: controls.filter(function (el) { return el.getBoundingClientRect().height < 43.5; }).map(function (el) { return el.outerHTML.slice(0, 80); }),
      hOverflow: document.documentElement.scrollWidth - vw
    };
  JS

  LIST_PROBE = <<~JS
    var rows = Array.prototype.slice.call(document.querySelectorAll("tbody tr"));
    var RESULT = {
      rows: rows.length,
      actionCounts: rows.map(function (tr) { return tr.querySelectorAll("td:last-child .btn").length; }),
      hOverflow: document.documentElement.scrollWidth - vw
    };
  JS

  # Game names are unique, so each long name carries a suffix.
  def finished_game(suffix = "")
    g = create_game(:author => superadmin, :is_draft => false, :name => ("Оченьдлинноеназваниеигрыбезпробелов" * 2) + suffix.to_s)
    create_level(:game => g)
    set_game_schedule!(g, :starts_at => 2.days.ago, :author_finished_at => 1.day.ago)
    g
  end

  %w[dark light].each do |theme|
    { "phone" => [ 390, 680 ], "laptop" => [ 845, 700 ], "desktop" => [ 1280, 800 ] }.each do |name, (width, height)|
      context "game page and list, #{theme} theme at #{width}x#{height} -- #{name}" do
        it "makes every control on the game page full-size, without sideways scroll" do
          m = measure_admin(superadmin_html(admin_game_path(finished_game)), width, height, theme, GAME_PAGE_PROBE)
          expect(m["count"]).to be >= 9
          expect(m["short"]).to eq([])
          expect(m["hOverflow"]).to be <= 0
        end

        it "gives each list row exactly two actions" do
          3.times { |i| finished_game(i) }
          m = measure_admin(superadmin_html(admin_games_path), width, height, theme, LIST_PROBE)
          # create_level's default :game is built eagerly (fixtures_helper), so
          # each level brings an extra game: assert every row, not a count.
          expect(m["rows"]).to be >= 3
          expect(m["actionCounts"].uniq).to eq([ 2 ])
          expect(m["hOverflow"]).to be <= 0
        end
      end
    end
  end

  PEOPLE_PROBE = <<~JS
    var controls = Array.prototype.slice.call(document.querySelectorAll(".admin-user .btn, .admin-user select, main details.row-more > summary"));
    var details = Array.prototype.slice.call(document.querySelectorAll("details.row-more"));
    var RESULT = {
      count: controls.length,
      short: controls.filter(function (el) { return el.getBoundingClientRect().height < 43.5; }).map(function (el) { return el.outerHTML.slice(0, 80); }),
      openDetails: details.filter(function (d) { return d.open; }).length,
      hOverflow: document.documentElement.scrollWidth - vw
    };
  JS

  %w[dark light].each do |theme|
    { "phone" => [ 390, 680 ], "laptop" => [ 845, 700 ], "desktop" => [ 1280, 800 ] }.each do |name, (width, height)|
      context "user page and teams list, #{theme} theme at #{width}x#{height} -- #{name}" do
        it "makes every user-page control full-size, without sideways scroll" do
          target = create_user
          create_team(:captain => create_user)
          m = measure_admin(superadmin_html(admin_user_path(target)), width, height, theme, PEOPLE_PROBE)
          expect(m["count"]).to be >= 5
          expect(m["short"]).to eq([])
          expect(m["hOverflow"]).to be <= 0
        end

        it "keeps every teams-list disclosure closed and full-size" do
          2.times { create_team }
          m = measure_admin(superadmin_html(admin_teams_path), width, height, theme, PEOPLE_PROBE)
          expect(m["openDetails"]).to eq(0)
          expect(m["short"]).to eq([])
          expect(m["hOverflow"]).to be <= 0
        end
      end
    end
  end
end
