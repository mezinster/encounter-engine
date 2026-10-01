require "rails_helper"
require "open3"
require "json"

describe "theme.js" do
  let(:script) { Rails.root.join("public/javascripts/theme.js").to_s }

  before do
    Open3.capture2("node", "--version") rescue raise("node is not on PATH; these examples must run, not skip")
  end

  def run_js(body)
    stdout, stderr, status = Open3.capture3("node", "-e", "var T = require(#{script.to_json});\n#{body}")
    raise "node harness failed: #{stderr}" unless status.success?
    JSON.parse(stdout.strip)
  end

  it "maps each theme to its page background" do
    expect(run_js('console.log(JSON.stringify([T.themeColorFor("dark"), T.themeColorFor("light")]))')).to eq(%w[#12100e #faf8f6])
  end

  # The meta tag must match the page behind the browser chrome; tokens.css is
  # the source of truth for those colours.
  it "agrees with tokens.css --bg for both themes" do
    css = Rails.root.join("public/stylesheets/tokens.css").read
    dark  = css[/:root[^{]*\{[^}]*?--bg:\s*(#[0-9a-f]{6})/i, 1]
    light = css[/\[data-theme="light"\][^{]*\{[^}]*?--bg:\s*(#[0-9a-f]{6})/i, 1]
    expect([ dark, light ].map(&:downcase)).to eq(run_js('console.log(JSON.stringify([T.themeColorFor("dark"), T.themeColorFor("light")]))'))
  end
end
