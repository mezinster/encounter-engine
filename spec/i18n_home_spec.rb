require "rails_helper"

# The home page's copy that a plain parity check cannot judge: deep links into
# each language's own manual (heading ids differ per language), the two date
# formats, and the team line's placeholder in the suffixing languages.
describe "home page copy" do
  LOCALES_FOR_HOME = %w[ru en uk be pl tr ka].freeze

  def value(locale, key)
    YAML.unsafe_load_file(Rails.root.join("config/locales/#{locale}.yml"))[locale].dig(*key.split("."))
  end

  LOCALES_FOR_HOME.each do |locale|
    it "points #{locale}'s manual links at real chapter headings of #{locale}'s manual" do
      html = Manual::Renderer.call(File.read(Rails.root.join("docs/manual/#{locale}.md"))).to_s
      ids = Nokogiri::HTML(html).css("h1, h2, h3").map { |h| h["id"] }

      expect(ids).to include(value(locale, "index.index.manual_player_anchor"))
      expect(ids).to include(value(locale, "index.index.manual_author_anchor"))
    end

    it "renders #{locale}'s home dates with a month name and the time" do
      time = Time.utc(2050, 10, 12, 21, 0)
      I18n.with_locale(locale) do
        expect(I18n.l(time, :format => :home_card)).to match(/\A12 \S+, 21:00\z/)
        expect(I18n.l(time, :format => :home_row)).to match(/\A12 \S+, 21:00\z/)
      end
    end
  end

  it "renders the Russian card date with the genitive month" do
    I18n.with_locale(:ru) { expect(I18n.l(Time.utc(2050, 10, 12, 21, 0), :format => :home_card)).to eq("12 октября, 21:00") }
  end

  # CLAUDE.md: Turkish and Georgian put case suffixes on a common noun, never on
  # a user-authored name. The team line must end the name with its closing
  # quote, with no suffix attached.
  %w[tr ka].each do |locale|
    it "keeps #{locale}'s team line free of a suffix on the team name" do
      expect(value(locale, "index.index.team_line")).to match(/«%\{team\}»\z/)
    end
  end
end
