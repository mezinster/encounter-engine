require "rails_helper"

describe Manual::Source do
  it "serves the Russian manual for ru" do
    document = described_class.for(:ru)

    expect(document.locale_used).to eq(:ru)
    expect(document.markdown).to include("# Руководство пользователя")
  end

  it "serves the English manual for en" do
    document = described_class.for(:en)

    expect(document.locale_used).to eq(:en)
    expect(document.markdown).to include("# User manual")
  end

  # Until sub-project B lands, five of the seven registered locales have no
  # manual. Falling back is fine; pretending it did not happen is not, which
  # is what locale_used is for -- the view renders a note when it differs.
  it "falls back to Russian for a locale with no manual, and says so" do
    document = described_class.for(:pl)

    expect(document.locale_used).to eq(:ru)
    expect(document.markdown).to include("# Руководство пользователя")
  end

  it "accepts a string locale" do
    expect(described_class.for("en").locale_used).to eq(:en)
  end

  it "digests the content it returns" do
    document = described_class.for(:ru)

    expect(document.digest)
      .to eq(Digest::SHA256.hexdigest(Rails.root.join("docs/manual/ru.md").read))
  end

  it "gives the same digest to two locales served by the same file" do
    expect(described_class.for(:pl).digest).to eq(described_class.for(:ru).digest)
  end

  # .dockerignore excludes docs/ wholesale, so an image built without the
  # re-include of Task 6 has no manual in it at all -- and every spec in this
  # repository would still pass, because they all run from a checkout. Fail
  # loudly and name the cause rather than returning nil for someone to
  # NoMethodError on three frames later.
  it "raises with the reason when the directory is not there" do
    Dir.mktmpdir do |empty|
      stub_const("Manual::Source::DIRECTORY", Pathname.new(empty))

      expect { described_class.for(:ru) }
        .to raise_error(Manual::Source::Missing, /dockerignore/)
    end
  end
end
