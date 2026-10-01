require "rails_helper"

describe "home-screen icon and manifest", type: :request do
  it "links the icons, the manifest and a theme colour, all versioned, before theme.js" do
    get root_path
    doc = Nokogiri::HTML(response.body)
    hrefs = %w[link[rel=apple-touch-icon] link[rel=manifest] link[rel=icon][type="image/svg+xml"]].map { |s| doc.at_css(s)&.[]("href") }
    expect(hrefs).to all(match(/\?v=[0-9a-f]{12}\z/))
    meta = doc.at_css('meta[name="theme-color"]')
    expect(meta["content"]).to eq("#12100e")
    head = doc.at_css("head").to_html
    expect(head.index('name="theme-color"')).to be < head.index("theme.js")
  end

  it "ships a manifest with the agreed fields" do
    manifest = JSON.parse(Rails.root.join("public/site.webmanifest").read)
    expect(manifest.values_at("name", "short_name", "display")).to eq([ "Активные городские игры", "Городские игры", "browser" ])
    expect(manifest["icons"].map { |i| i["src"] }).to all(satisfy { |src| Rails.root.join("public", src.delete_prefix("/")).exist? })
  end
end
