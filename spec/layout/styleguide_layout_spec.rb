require "rails_helper"
require_relative "../support/layout_measurement"

# The styleguide, measured in a real browser in both themes. Neither suite
# can see contrast, tap size or computed font size; this is where the form
# system's promises are checked. Excluded from the default run (needs
# chrome-headless-shell); run with LAYOUT_SPECS=1. A missing browser raises.
describe "the styleguide, measured", :layout, type: :request do
  include LayoutMeasurement

  let(:page_html) do
    admin = create_user
    admin.update!(:is_superadmin => true)
    put login_path, :params => { :email => admin.email, :password => "1234" }
    get admin_styleguide_path
    expect(response).to have_http_status(:ok)
    response.body
  end

  def probe(theme)
    <<~JS
      document.documentElement.setAttribute("data-theme", "#{theme}");

      function rgb(s) { var m = s.match(/[\\d.]+/g).map(Number); return { r: m[0], g: m[1], b: m[2], a: m.length > 3 ? m[3] : 1 }; }
      function lum(c) {
        var f = function (v) { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); };
        return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
      }
      function ratio(a, b) { var x = lum(a), y = lum(b); return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05); }
      function backdrop(el) {
        for (var n = el.parentElement; n; n = n.parentElement) {
          var c = rgb(getComputedStyle(n).backgroundColor);
          if (c.a > 0) return c;
        }
        return rgb(getComputedStyle(document.body).backgroundColor);
      }

      // WCAG 1.4.11 exempts inactive components, so :disabled is excluded --
      // by the pseudo-class, not by any class name.
      var controls = Array.prototype.slice.call(document.querySelectorAll(
        ".styleguide input:not([type=checkbox]):not([type=radio]):not([type=file]):not(:disabled), " +
        ".styleguide select:not(:disabled), .styleguide textarea:not(:disabled)"
      ));
      var lowContrast = controls.map(function (el) {
        var s = getComputedStyle(el), border = rgb(s.borderTopColor);
        var fill = rgb(s.backgroundColor);
        var worst = Math.min(ratio(border, fill), ratio(border, backdrop(el)));
        return { id: el.id || el.name || el.type, worst: Math.round(worst * 100) / 100 };
      }).filter(function (c) { return c.worst < 3; });

      var shortTargets = Array.prototype.slice.call(document.querySelectorAll(".styleguide .btn, .styleguide .check, .styleguide .empty-state-action"))
        .map(function (el) { return { text: el.textContent.trim().slice(0, 30), h: Math.round(el.getBoundingClientRect().height) }; })
        .filter(function (t) { return t.h < 44; });

      // The allowed sizes are read from the tokens in this page, at this
      // viewport -- the clamps resolve differently at 390 and 1280.
      var steps = ["xs", "sm", "md", "lg", "xl", "2xl", "body", "h1", "h2"];
      var allowed = steps.map(function (s) {
        var d = document.createElement("span");
        d.style.fontSize = "var(--text-" + s + ")";
        document.body.appendChild(d);
        var px = parseFloat(getComputedStyle(d).fontSize);
        d.remove();
        return px;
      });
      function inScale(px) { return allowed.some(function (a) { return Math.abs(a - px) < 0.05; }); }
      var offScale = Array.prototype.slice.call(document.body.querySelectorAll("*"))
        .filter(function (el) {
          if (el.closest("script, style, pre")) return false;
          if (el.matches("input[type=checkbox], input[type=radio]")) return false;
          if (el.matches("input, select, textarea, button")) return true;
          return Array.prototype.some.call(el.childNodes, function (n) { return n.nodeType === 3 && n.textContent.trim() !== ""; });
        })
        .map(function (el) { return { tag: el.tagName.toLowerCase() + (el.className ? "." + String(el.className).split(" ").join(".") : ""), px: parseFloat(getComputedStyle(el).fontSize) }; })
        .filter(function (e) { return !inScale(e.px); });

      var dangerProbe = document.createElement("span");
      dangerProbe.style.color = "var(--danger)";
      document.body.appendChild(dangerProbe);
      var danger = getComputedStyle(dangerProbe).color;
      dangerProbe.remove();
      // Radios and checkboxes are excluded: a native-appearance control ignores
      // border-color in Chrome (computed stays black even with an inline style),
      // so there is no border to measure on them.
      var invalid = Array.prototype.slice.call(document.querySelectorAll(
        ".styleguide .is-invalid:is(input, select, textarea):not([type=radio]):not([type=checkbox])"));
      var invalidNotRed = invalid.map(function (el) { return { id: el.id || el.name, border: getComputedStyle(el).borderTopColor }; })
        .filter(function (e) { return e.border !== danger; });
      var fieldChecks = Array.prototype.slice.call(document.querySelectorAll(".styleguide .field > label.check"));
      var fieldChecksNotFlex = fieldChecks.map(function (el) { return getComputedStyle(el).display; })
        .filter(function (d) { return d !== "flex"; });
      var thumbs = Array.prototype.slice.call(document.querySelectorAll(".styleguide .file-thumb-generic"));
      var thumbsOverflowing = thumbs.filter(function (el) { return el.scrollWidth > el.clientWidth || el.scrollHeight > el.clientHeight; })
        .map(function (el) { return { lang: el.lang, sw: el.scrollWidth, cw: el.clientWidth, sh: el.scrollHeight, ch: el.clientHeight }; });

      var empties = Array.prototype.slice.call(document.querySelectorAll(".styleguide .empty-state"));
      var emptyGaps = empties.map(function (c) { var k = c.children; var g = []; for (var i = 1; i < k.length; i++) g.push(k[i].getBoundingClientRect().top - k[i-1].getBoundingClientRect().bottom); return g; });

      var RESULT = {
        emptyCount: empties.length, emptyMinGap: Math.min.apply(null, [].concat.apply([], emptyGaps).concat([999])),
        invalidCount: invalid.length, invalidNotRed: invalidNotRed,
        fieldCheckCount: fieldChecks.length, fieldChecksNotFlex: fieldChecksNotFlex,
        thumbCount: thumbs.length,
        // The thumbnail is an icon plus a visually-hidden label now; this guards
        // against text styling creeping back onto the box.
        thumbsShouted: thumbs.filter(function (el) { var s = getComputedStyle(el); return s.textTransform !== "none" || s.letterSpacing !== "normal"; }).length, thumbsOverflowing: thumbsOverflowing,
        theme: document.documentElement.getAttribute("data-theme"),
        controls: controls.length,
        lowContrast: lowContrast,
        shortTargets: shortTargets,
        offScale: offScale,
        hOverflow: document.documentElement.scrollWidth - document.documentElement.clientWidth
      };
    JS
  end

  %w[dark light].each do |theme|
    { "phone" => [ 390, 680 ], "desktop" => [ 1280, 800 ] }.each do |name, (width, height)|
      context "#{theme} theme at #{width}x#{height} -- #{name}" do
        let(:m) { measure(page_html, width, height, probe(theme), :tmp_name => "styleguide-measure.html") }

        it "measured the theme it was asked for, and found controls to measure" do
          expect(m["theme"]).to eq(theme)
          expect(m["controls"]).to be >= 12
        end

        it "draws every enabled form control's border at 3:1 or better" do
          expect(m["lowContrast"]).to eq([])
        end

        it "makes every button and check row at least 44px tall" do
          expect(m["shortTargets"]).to eq([])
        end

        it "puts every text size on the type scale" do
          expect(m["offScale"]).to eq([])
        end

        it "draws every invalid control's border in --danger" do
          expect(m["invalidCount"]).to be >= 3
          expect(m["invalidNotRed"]).to eq([])
        end

        it "lays out a .check inside a .field as a flex row" do
          expect(m["fieldCheckCount"]).to be >= 1
          expect(m["fieldChecksNotFlex"]).to eq([])
        end

        it "fits the generic thumbnail icon in its box, in every locale" do
          expect(m["thumbCount"]).to eq(7)
          expect(m["thumbsShouted"]).to eq(0)
          expect(m["thumbsOverflowing"]).to eq([])
        end

        it "lays out an empty state with visible gaps" do
          expect(m["emptyCount"]).to be >= 1
          expect(m["emptyMinGap"]).to be >= 4
        end

        it "does not scroll sideways" do
          expect(m["hOverflow"]).to eq(0)
        end
      end
    end
  end
end
