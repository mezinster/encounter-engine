require "rails_helper"

# Vendored widgets this repository has retired. A later revert of one view
# must not quietly reintroduce a <script src> or <link> to a deleted file.
describe "retired assets" do
  RETIRED_ASSETS = %w[
    calendar.js calendar-setup.js calendar-ru-UTF.js calendar.css
    active-bg.gif dark-bg.gif hover-bg.gif menuarrow.gif normal-bg.gif
    rowhover-bg.gif status-bg.gif title-bg.gif today-bg.gif
    jquery.autocomplete.js jquery.autocomplete.css
  ].freeze

  it "are gone from disk" do
    present = RETIRED_ASSETS.select { |name| Dir[Rails.root.join("public/**/#{name}")].any? }
    expect(present).to eq([])
  end

  it "are referenced nowhere in app/ or public/" do
    files = Dir[Rails.root.join("{app,public}/**/*.{erb,rb,js,css,html}")]
    hits = files.flat_map do |path|
      text = File.read(path)
      RETIRED_ASSETS.select { |name| text.include?(name) }.map { |name| "#{path.sub("#{Rails.root}/", "")}: #{name}" }
    end
    expect(hits).to eq([])
  end
end
