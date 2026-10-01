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
    _, status = Open3.capture2("node", "--version") rescue raise("node is not on PATH; these examples must run, not skip")
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
end
