require "rails_helper"
require_relative "../support/layout_measurement"

# The home page, measured in a real browser in both themes, guest and signed
# in. Excluded from the default run (needs chrome-headless-shell);
# LAYOUT_SPECS=1. A missing browser raises.
describe "the home page, measured", :layout, type: :request do
  include LayoutMeasurement

  def page_html(signed_in:)
    captain = create_user
    team = create_team(:captain => captain)
    [["Оченьдлинноеназваниеигрыбезпробеловкотороенедолжнорасширятьстраницу", 12.hours.from_now],
     ["Ночной Бишкек", 1.day.from_now], ["Тайны старого города", 2.days.from_now],
     ["Очень длинное название игры, которое не должно сдвигать статус за край экрана", 3.days.from_now]].each do |name, at|
      game = create_game(:name => name)
      set_game_schedule!(game, :starts_at => at)
      create_game_entry(:game => game, :team => team, :status => "rejected") if name.start_with?("Очень")
    end
    put login_path, :params => { :email => captain.email, :password => "1234" } if signed_in
    get root_path
    expect(response).to have_http_status(:ok)
    response.body
  end

  def probe(theme)
    <<~JS
      document.documentElement.setAttribute("data-theme", "#{theme}");
      var tappables = Array.prototype.slice.call(document.querySelectorAll(".home .btn, .home .link-tap, .home button, .home a.name, .home .next-game h3 a"));
      var tags = Array.prototype.slice.call(document.querySelectorAll(".home .tag"));
      var nums = Array.prototype.slice.call(document.querySelectorAll(".timeline .num"));
      var home = document.querySelector(".home");
      function tag(el) { return el.tagName.toLowerCase() + (el.className ? "." + String(el.className).split(" ").join(".") : ""); }
      var tightPairs = [], pairCount = 0;
      Array.prototype.slice.call(document.querySelectorAll(".home-upcoming, #how-to-play, .home-organizers")).forEach(function (sec) {
        var kids = Array.prototype.slice.call(sec.children);
        for (var i = 1; i < kids.length; i++) {
          pairCount++;
          var gap = kids[i].getBoundingClientRect().top - kids[i - 1].getBoundingClientRect().bottom;
          if (gap < 8) tightPairs.push((sec.id ? "#" + sec.id : tag(sec)) + ": " + tag(kids[i - 1]) + " -> " + tag(kids[i]) + " (" + Math.round(gap * 10) / 10 + "px)");
        }
      });
      Array.prototype.slice.call(document.querySelectorAll(".timeline li")).forEach(function (li) {
        var h = li.querySelector("h3"), p = li.querySelector("p");
        if (!h || !p) return;
        var gap = p.getBoundingClientRect().top - h.getBoundingClientRect().bottom;
        if (gap < 2) tightPairs.push(".timeline li: h3 -> p (" + Math.round(gap * 10) / 10 + "px)");
      });
      var RESULT = {
        tightPairs: tightPairs,
        pairCount: pairCount,
        tagCount: tags.length,
        theme: document.documentElement.getAttribute("data-theme"),
        tappableCount: tappables.length,
        shortTaps: tappables.filter(function (el) { return el.getBoundingClientRect().height < 43.5; })
                            .map(function (el) { return el.textContent.trim(); }),
        wrappedTags: tags.filter(function (el) { return el.getClientRects().length > 1 ||
                                  el.getBoundingClientRect().height > parseFloat(getComputedStyle(el).lineHeight) * 1.5; })
                         .map(function (el) { return el.textContent.trim(); }),
        tagsInside: tags.every(function (el) { return el.getBoundingClientRect().right <= document.documentElement.clientWidth + 0.5; }),
        numCount: nums.length,
        numsCentred: nums.every(function (el) {
          var li = el.parentElement, line = getComputedStyle(li, "::before"), r = el.getBoundingClientRect(), lr = li.getBoundingClientRect();
          if (li === li.parentElement.lastElementChild) return true;
          var lineX = lr.left + parseFloat(line.left) + parseFloat(line.width) / 2;
          return Math.abs((r.left + r.width / 2) - lineX) <= 1;
        }),
        homeWidth: Math.round(home.getBoundingClientRect().width),
        remPx: parseFloat(getComputedStyle(document.documentElement).fontSize),
        hOverflow: document.documentElement.scrollWidth - document.documentElement.clientWidth
      };
    JS
  end

  [true, false].each do |signed_in|
    %w[dark light].each do |theme|
      { "phone" => [ 390, 680 ], "desktop" => [ 1280, 800 ] }.each do |name, (width, height)|
        context "#{signed_in ? "signed in" : "guest"}, #{theme} theme at #{width}x#{height} -- #{name}" do
          let(:m) { measure(page_html(:signed_in => signed_in), width, height, probe(theme), :tmp_name => "home-measure.html") }

          it "measured the theme it was asked for" do
            expect(m["theme"]).to eq(theme)
            expect(m["tappableCount"]).to be >= 2
          end

          it "keeps every button and link at least 44px tall" do
            expect(m["shortTaps"]).to eq([])
          end

          it "keeps every status tag on one line and on screen" do
            expect(m["tagCount"]).to be >= 1
            expect(m["wrappedTags"]).to eq([])
            expect(m["tagsInside"]).to be(true)
          end

          it "does not scroll sideways" do
            expect(m["hOverflow"]).to eq(0)
          end

          it "keeps a visible gap between blocks inside each section" do
            expect(m["pairCount"]).to be > 0
            expect(m["tightPairs"]).to eq([])
          end

          if name == "desktop"
            it "caps the content at 44rem" do
              expect(m["homeWidth"]).to be <= (44 * m["remPx"]).ceil
            end
          end

          unless signed_in
            it "centres each timeline number on its connecting line" do
              expect(m["numCount"]).to eq(3)
              expect(m["numsCentred"]).to be(true)
            end
          end
        end
      end
    end
  end
end
