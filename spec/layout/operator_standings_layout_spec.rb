require "rails_helper"
require_relative "../support/layout_measurement"

# The operator's standings screen (/stats/index/:game_id), measured in a real
# browser on phones and desktop, both themes. Excluded from the default run
# (needs chrome-headless-shell); LAYOUT_SPECS=1. A missing browser raises.
describe "the operator's standings, measured", :layout, type: :request do
  include LayoutMeasurement

  LONG_TEAM = "Оченьдлинноеназваниеко" \
              "мандыбезпробеловкотороенедолжнорасширятьстраницу".freeze

  TEAM_NAMES = [
    "Ночные Волки", "Сфинкс", "Бишкекские Тигры", "Альфа", "Зелёный Свет", "Северный Ветер",
    "Эрудиты", "Рассвет", "Три Кота", "Охотники за Кодами", "Каравелла", LONG_TEAM
  ].freeze

  def page_html(paused:)
    author = create_user
    game = create_game(:author => author)
    attrs = { :starts_at => 1.hour.ago }
    attrs[:paused_at] = 5.minutes.ago if paused
    set_game_schedule!(game, attrs)
    levels = (1..8).map { |i| create_level(:game => game, :name => "Уровень #{i}") }
    TEAM_NAMES.each_with_index do |name, i|
      team = Team.new(:name => name, :captain => create_user)
      team.save!
      create_game_passing(:game => game, :level => levels[i % levels.size], :team => team)
    end
    put login_path, :params => { :email => author.email, :password => "1234" }
    get game_stats_path(game)
    expect(response).to have_http_status(:ok)
    response.body
  end

  # The live-region script does not load from the file:// copy, so the probe
  # unhides the status line and gives its stamp text: the bar at its fullest.
  # The short-row check skips the deliberately unbroken long-name team, whose
  # name cannot fit two lines in half a phone width; that row is covered by
  # the overflow and disclosure-inside examples.
  def probe(theme)
    <<~JS
      document.documentElement.setAttribute("data-theme", "#{theme}");
      // Server-rendered bar text, captured before the probe touches anything.
      // The parser closes the <p class="game-control"> before the button_to form,
      // so the bar's text is read from the whole .opbar (live status is hidden
      // and empty at this point).
      var barTextBeforeProbe = document.querySelector(".opbar").textContent.replace(/\\s+/g, " ").trim();
      var pauseLabel = document.querySelector(".opbar form.button_to button").textContent.trim();
      var status = document.querySelector("[data-live-status]");
      var statusDisplayBeforeScript = status ? getComputedStyle(status).display : "absent";
      if (status) { status.hidden = false;
        status.querySelector("[data-live-stamp]").textContent = "Обновлено 12 с назад";
        status.querySelector("[data-live-toggle]").textContent = "Пауза обновления"; }
      var vw = document.documentElement.clientWidth;
      function hit(el) { var r = el.getBoundingClientRect(); if (r.width === 0) return false;
        var t = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2); return !!t && (t === el || el.contains(t)); }
      var pause = document.querySelector(".opbar form.button_to button");
      var pauseTop = hit(pause);
      var scrollable = document.documentElement.scrollHeight > window.innerHeight + 50;
      window.scrollTo(0, document.documentElement.scrollHeight);
      var pauseBottom = hit(pause);
      window.scrollTo(0, 0);
      var rows = Array.prototype.slice.call(document.querySelectorAll("#stats tbody tr"));
      // Row heights are taken BEFORE a panel is opened: an open panel is
      // meant to make its own row tall.
      var rowHeights = rows.filter(function (r) { return r.textContent.indexOf("Оченьдлинноеназваниеко") === -1; })
                           .map(function (r) { return Math.round(r.getBoundingClientRect().height); });
      // Text of the name/level/time cells must never run under the panel
      // button: compare each text line's box with the button's box.
      function overlaps(a, b) { return a.left < b.right - 0.5 && b.left < a.right - 0.5 && a.top < b.bottom - 0.5 && b.top < a.bottom - 0.5; }
      var rowsWithButton = rows.filter(function (r) { return !!r.querySelector(".team-disclosure"); }).length;
      var rectsCompared = 0;
      var textUnderButton = rows.filter(function (r) {
        var btn = r.querySelector(".team-disclosure"); if (!btn) return false;
        var br = btn.getBoundingClientRect();
        return Array.prototype.some.call(r.querySelectorAll(".standings-team, .standings-level, .standings-time"), function (c) {
          var range = document.createRange(); range.selectNodeContents(c);
          return Array.prototype.some.call(range.getClientRects(), function (q) { if (q.width > 0) rectsCompared++; return q.width > 0 && overlaps(q, br); });
        });
      }).map(function (r) { return r.querySelector(".standings-team").textContent.trim().slice(0, 20); });
      var firstDetails = document.querySelector("#stats details"); firstDetails.open = true;
      var panelControls = Array.prototype.slice.call(firstDetails.querySelectorAll(".team-panel .btn, .team-panel select, .team-panel button, .team-panel input[type=submit]"));
      var scrollers = Array.prototype.slice.call(document.querySelectorAll("body *")).filter(function (el) {
        var s = getComputedStyle(el); return (s.overflowX === "auto" || s.overflowX === "scroll") && el.scrollWidth > el.clientWidth + 1; });
      var RESULT = {
        theme: document.documentElement.getAttribute("data-theme"),
        rowCount: rows.length,
        barTextBeforeProbe: barTextBeforeProbe, pauseLabel: pauseLabel, scrollable: scrollable,
        measuredHeights: rowHeights.length, rowsWithButton: rowsWithButton, rectsCompared: rectsCompared,
        tallRows: rowHeights.filter(function (h) { return h > 90; }),
        textUnderButton: textUnderButton,
        statusDisplayBeforeScript: statusDisplayBeforeScript,
        pauseTop: pauseTop, pauseBottom: pauseBottom,
        panelControlCount: panelControls.length,
        shortControls: panelControls.filter(function (el) { return el.getBoundingClientRect().height < 43.5; }).map(function (el) { return el.textContent.trim() || el.tagName; }),
        logCellDisplays: Array.prototype.slice.call(document.querySelectorAll("#stats .standings-log")).map(function (el) { return getComputedStyle(el).display; }).filter(function (v, i, a) { return a.indexOf(v) === i; }),
        summaryText: document.querySelector(".team-disclosure").textContent,
        summaryW: Math.round(document.querySelector(".team-disclosure").getBoundingClientRect().width * 10) / 10,
        summaryH: Math.round(document.querySelector(".team-disclosure").getBoundingClientRect().height * 10) / 10,
        disclosureInside: Array.prototype.slice.call(document.querySelectorAll(".team-disclosure")).every(function (el) { return el.getBoundingClientRect().right <= vw + 0.5; }),
        innerScrollers: scrollers.map(function (el) { return (el.id || el.className || el.tagName) + ":" + el.scrollWidth; }),
        hOverflow: document.documentElement.scrollWidth - vw
      };
    JS
  end

  contexts = []
  %w[dark light].each do |theme|
    { "phone" => [ 390, 680 ], "small phone" => [ 375, 553 ], "desktop" => [ 1280, 800 ] }.each do |name, (w, h)|
      contexts << [ theme, name, w, h, false ]
    end
  end
  contexts << [ "dark", "phone", 390, 680, true ]

  contexts.each do |theme, name, width, height, paused|
    context "#{paused ? "paused, " : ""}#{theme} theme at #{width}x#{height} -- #{name}" do
      let(:m) { measure(page_html(:paused => paused), width, height, probe(theme), :tmp_name => "operator-standings-measure.html") }

      it "measured the theme it was asked for" do
        expect(m["theme"]).to eq(theme)
        expect(m["rowCount"]).to eq(12)
      end

      it "rendered the paused or running state it was asked for" do
        if paused
          expect(m["barTextBeforeProbe"]).to include("Игра приостановлена в")
          expect(m["pauseLabel"]).to eq("Продолжить игру")
        else
          expect(m["barTextBeforeProbe"]).not_to include("Игра приостановлена")
          expect(m["pauseLabel"]).to eq("Приостановить игру")
        end
      end

      it "lets Pause/Resume be tapped at the top and the bottom of the scroll" do
        expect(m["pauseTop"]).to be(true)
        # Sticky on phones only; on desktop the bar sits at the top by design.
        if name != "desktop"
          expect(m["scrollable"]).to be(true)
          expect(m["pauseBottom"]).to be(true)
        end
      end

      it "keeps the refresh status line hidden until the script runs" do
        expect(m["statusDisplayBeforeScript"]).to eq("none")
      end

      it "keeps every control in an opened panel at least 44px tall" do
        expect(m["panelControlCount"]).to be >= 3
        expect(m["shortControls"]).to eq([])
      end

      it "does not scroll sideways, on the page or inside anything" do
        expect(m["hOverflow"]).to eq(0)
        expect(m["innerScrollers"]).to eq([])
      end

      if name == "desktop"
        it "keeps the log-link columns on desktop" do
          expect(m["logCellDisplays"]).to eq([ "table-cell" ])
        end
      else
        it "keeps each team to a short row" do
          expect(m["measuredHeights"]).to eq(11)
          expect(m["tallRows"]).to eq([])
        end

        it "hides the frozen log-link cells and keeps the panel button on screen" do
          expect(m["logCellDisplays"]).to eq([ "none" ])
          expect(m["disclosureInside"]).to be(true)
        end

        it "keeps the icon-sized panel summary labelled and tappable" do
          expect(m["summaryText"]).to include("Вмешательство")
          expect(m["summaryW"]).to be >= 43.5
          expect(m["summaryH"]).to be >= 43.5
        end

        it "keeps every line of team text clear of the panel button" do
          expect(m["rowsWithButton"]).to eq(12)
          expect(m["rectsCompared"]).to be > 0
          expect(m["textUnderButton"]).to eq([])
        end
      end
    end
  end
end
