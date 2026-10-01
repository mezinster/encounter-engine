require "rails_helper"
require "open3"
require "json"

# public/javascripts/live_region.js, run under Node -- the same reasoning as
# spec/views/countdown_spec.rb: assert what the shipped JavaScript actually
# does, not a Ruby mirror of it. A missing node RAISES rather than skips (CI
# installs it; a skip would read like a pass).
describe "live_region.js" do
  let(:script) { Rails.root.join("public/javascripts/live_region.js").to_s }

  before do
    Open3.capture2("node", "--version") rescue raise("node is not on PATH; these examples must run, not skip")
  end

  def run_js(body)
    harness = "var LR = require(#{script.to_json});\n#{body}"
    stdout, stderr, status = Open3.capture3("node", "-e", harness)
    raise "node harness failed: #{stderr}" unless status.success?
    JSON.parse(stdout.strip)
  end

  # Fakes: only the members the functions read.
  let(:fakes) do
    <<~JS
      function region(open) { return { querySelector: function (s) { return s === "details[open]" && open ? {} : null; } }; }
      function doc(hidden, tag) { return { hidden: hidden, activeElement: tag ? { tagName: tag } : null }; }
    JS
  end

  it "holds while the tab is hidden, a panel is open, or a field has focus" do
    result = run_js(fakes + <<~JS)
      console.log(JSON.stringify([
        LR.holdReason(doc(true, null), region(false)),
        LR.holdReason(doc(false, null), region(true)),
        LR.holdReason(doc(false, "SELECT"), region(false)),
        LR.holdReason(doc(false, "INPUT"), region(false)),
        LR.holdReason(doc(false, "TEXTAREA"), region(false)),
        LR.holdReason(doc(false, "BUTTON"), region(false)),
        LR.holdReason(doc(false, null), region(false))
      ]));
    JS
    expect(result).to eq(["hidden", "panel", "focus", "focus", "focus", nil, nil])
  end

  it "formats the stamp from the translated template" do
    result = run_js('console.log(JSON.stringify(LR.formatStamp("Обновлено %{seconds} с назад", 12)));')
    expect(result).to eq("Обновлено 12 с назад")
  end

  it "remembers the paused state, and survives a storage that throws" do
    result = run_js(<<~JS)
      var mem = {}; var good = { getItem: function (k) { return mem[k] || null; },
                                 setItem: function (k, v) { mem[k] = v; }, removeItem: function (k) { delete mem[k]; } };
      var bad = { getItem: function () { throw new Error("denied"); }, setItem: function () { throw new Error("denied"); },
                  removeItem: function () { throw new Error("denied"); } };
      var before = LR.readPaused(good); LR.writePaused(good, true); var after = LR.readPaused(good);
      LR.writePaused(good, false); var cleared = LR.readPaused(good);
      LR.writePaused(bad, true);
      console.log(JSON.stringify([before, after, cleared, LR.readPaused(bad), LR.readPaused(null)]));
    JS
    expect(result).to eq([false, true, false, false, false])
  end

  # A fetched page without the region -- the login page after the session
  # expired, an error page -- must swap nothing.
  it "finds the region in a fetched page, and returns null when it is absent" do
    result = run_js(<<~JS)
      function parse(html) { return { getElementById: function (id) { return html.indexOf('id="' + id + '"') >= 0 ? { innerHTML: "fresh" } : null; } }; }
      var found = LR.extractRegion(parse, '<div id="standings-live">x</div>', "standings-live");
      var missing = LR.extractRegion(parse, '<form id="login">', "standings-live");
      var unparsable = LR.extractRegion(function () { return null; }, "", "standings-live");
      console.log(JSON.stringify([found && found.innerHTML, missing, unparsable]));
    JS
    expect(result).to eq(["fresh", nil, nil])
  end

  it "holds while focus is on a link inside the region" do
    result = run_js(<<~JS)
      var inside = { tagName: "A" };
      var region = { querySelector: function () { return null; }, contains: function (n) { return n === inside; } };
      var other = { tagName: "A" };
      console.log(JSON.stringify([
        LR.holdReason({ hidden: false, activeElement: inside, body: {} }, region),
        LR.holdReason({ hidden: false, activeElement: other, body: {} }, region)
      ]));
    JS
    expect(result).to eq(["focus", nil])
  end

  it "does not hold on a closed panel's summary, but still holds on other focus in the region" do
    result = run_js(<<~JS)
      var summary = { tagName: "SUMMARY", parentNode: { tagName: "DETAILS", open: false } };
      var openSummary = { tagName: "SUMMARY", parentNode: { tagName: "DETAILS", open: true } };
      var link = { tagName: "A", parentNode: { tagName: "P" } };
      function region(openPanel) { return { querySelector: function (s) { return s === "details[open]" && openPanel ? {} : null; },
                                            contains: function () { return true; } }; }
      function doc(el) { return { hidden: false, activeElement: el, body: {} }; }
      console.log(JSON.stringify([
        LR.holdReason(doc(summary), region(false)),
        LR.holdReason(doc(openSummary), region(true)),
        LR.holdReason(doc(link), region(false))
      ]));
    JS
    expect(result).to eq([nil, "panel", "focus"])
  end

  it "fetches again after a network error or a non-2xx response" do
    result = run_js(start_harness + <<~JS)
      (async function () {
        var h = make(); h.hook.tick();
        h.fetches[0].reject(new Error("offline")); await settle();
        h.hook.tick();
        h.fetches[1].resolve({ ok: false, text: function () { return Promise.resolve("boom"); } }); await settle();
        h.hook.tick();
        console.log(JSON.stringify([h.fetches.length, h.region.innerHTML, h.swaps]));
      })();
    JS
    expect(result).to eq([3, "old", 0])
  end

  # start() driven with small fakes. Every fetch is a promise the example
  # resolves by hand; setInterval/setTimeout callbacks are captured.
  let(:start_harness) do
    <<~JS
      function make(opts) {
        opts = opts || {};
        var h = { fetches: [], timers: [], aborts: 0, swaps: 0, detailsOpen: false };
        var region = { id: "r", _html: "old",
          get innerHTML() { return this._html; }, set innerHTML(v) { this._html = v; h.swaps++; },
          querySelector: function (s) { return s === "details[open]" && h.detailsOpen ? {} : null; },
          contains: function () { return false; } };
        var stamp = {}, toggle = { addEventListener: function () {}, setAttribute: function () {} };
        var status = { hidden: true,
          getAttribute: function () { return "x"; },
          querySelector: function (s) { return s === "[data-live-stamp]" ? stamp : toggle; } };
        var doc = { hidden: false, activeElement: null, body: {},
          querySelector: function (s) { return s === "[data-live]" ? region : s === "[data-live-status]" ? status : null; } };
        var win = { location: { href: "/x" }, scrollX: 0, scrollY: 0, scrollTo: function () {},
          fetch: function (url, o) {
            var f = {}; f.promise = new Promise(function (res, rej) { f.resolve = res; f.reject = rej; });
            f.signal = o.signal; h.fetches.push(f); return f.promise; },
          DOMParser: function () { this.parseFromString = function (html) {
            return { getElementById: function (id) { return html.indexOf('id="' + id + '"') >= 0 ? { innerHTML: "fresh" } : null; } }; }; },
          setInterval: function () { return 1; },
          setTimeout: function (fn, ms) { h.ms = ms; h.timers.push({ fn: fn, ms: ms }); return h.timers.length; },
          clearTimeout: function (id) { h.timers[id - 1] = null; } };
        if (!opts.noAbort) win.AbortController = function () { var self = this; this.signal = {};
          this.abort = function () { h.aborts++; }; };
        h.region = region; h.hook = LR.start(doc, win);
        return h;
      }
      function ok(body) { return { ok: true, text: function () { return Promise.resolve(body); } }; }
      function settle() { return new Promise(function (r) { setTimeout(r, 0); }); }
    JS
  end

  it "skips a tick while a request is pending, and fetches again once it completes" do
    result = run_js(start_harness + <<~JS)
      (async function () {
        var h = make(); h.hook.tick(); h.hook.tick();
        var during = h.fetches.length;
        h.fetches[0].resolve(ok('<div id="r">x</div>')); await settle();
        h.hook.tick();
        console.log(JSON.stringify([during, h.fetches.length, h.region.innerHTML, h.ms]));
      })();
    JS
    expect(result).to eq([1, 2, "fresh", 15000])
  end

  it "swaps nothing when the response lacks the region" do
    result = run_js(start_harness + <<~JS)
      (async function () {
        var h = make(); h.hook.tick();
        h.fetches[0].resolve(ok('<form id="login"></form>')); await settle();
        h.hook.tick();
        console.log(JSON.stringify([h.region.innerHTML, h.swaps, h.fetches.length]));
      })();
    JS
    expect(result).to eq(["old", 0, 2])
  end

  it "does not swap when a panel was opened while the fetch was in flight" do
    result = run_js(start_harness + <<~JS)
      (async function () {
        var h = make(); h.hook.tick();
        h.detailsOpen = true;
        h.fetches[0].resolve(ok('<div id="r">x</div>')); await settle();
        console.log(JSON.stringify([h.region.innerHTML, h.swaps]));
      })();
    JS
    expect(result).to eq(["old", 0])
  end

  it "ignores a response that arrives after the request timed out, and frees the next tick" do
    result = run_js(start_harness + <<~JS)
      (async function () {
        var h = make(); h.hook.tick();
        h.timers[0].fn();
        h.hook.tick();
        var fetchedAgain = h.fetches.length;
        h.fetches[0].resolve(ok('<div id="r">x</div>')); await settle();
        console.log(JSON.stringify([h.aborts, fetchedAgain, h.region.innerHTML, h.swaps]));
      })();
    JS
    expect(result).to eq([1, 2, "old", 0])
  end

  it "still prevents overlap without AbortController" do
    result = run_js(start_harness + <<~JS)
      (async function () {
        var h = make({ noAbort: true }); h.hook.tick(); h.hook.tick();
        console.log(JSON.stringify([h.fetches.length, h.fetches[0].signal === undefined]));
      })();
    JS
    expect(result).to eq([1, true])
  end
end
