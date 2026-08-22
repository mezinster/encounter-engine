require "rails_helper"
require "tmpdir"
require "fileutils"

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
  # Against a directory holding only ru.md, rather than against whichever
  # language happens to be untranslated today. This example used to ask for
  # Polish and get Russian, which stopped being true the moment pl.md was
  # written -- so the fallback path would have quietly lost its only test at
  # exactly the moment the translations arrived. What is being tested is the
  # behaviour when a manual is missing, not the state of the docs directory.
  it "falls back to Russian for a locale with no manual, and says so" do
    Dir.mktmpdir do |only_russian|
      FileUtils.cp(Rails.root.join("docs/manual/ru.md"), File.join(only_russian, "ru.md"))
      stub_const("Manual::Source::DIRECTORY", Pathname.new(only_russian))

      document = described_class.for(:pl)

      expect(document.locale_used).to eq(:ru)
      expect(document.markdown).to include("# Руководство пользователя")
    end
  end

  it "reports which locales have a manual of their own" do
    expect(described_class.available_locales).to include(:ru, :en)
  end

  # deployment.en.md and performance.ru.md live in the same directory and are
  # not locales. A basename-only rule would report :deployment and :performance
  # as available languages.
  it "does not mistake the other documents in the directory for locales" do
    expect(described_class.available_locales)
      .to all(satisfy { |locale| I18n.available_locales.include?(locale) })
  end

  it "accepts a string locale" do
    expect(described_class.for("en").locale_used).to eq(:en)
  end

  it "digests the content it returns" do
    document = described_class.for(:ru)

    expect(document.digest)
      .to eq(Digest::SHA256.hexdigest(Rails.root.join("docs/manual/ru.md").read))
  end

  # Two locales that fall back to the same file share one cache entry in
  # ManualController, which is the whole reason the key is the digest and not
  # the requested locale. Driven against a Russian-only directory: this
  # example used to pair :pl with :ru, and stopped meaning anything the day
  # pl.md was written, because the two then legitimately differ.
  it "gives the same digest to two locales served by the same file" do
    Dir.mktmpdir do |only_russian|
      FileUtils.cp(Rails.root.join("docs/manual/ru.md"), File.join(only_russian, "ru.md"))
      stub_const("Manual::Source::DIRECTORY", Pathname.new(only_russian))

      expect(described_class.for(:pl).digest).to eq(described_class.for(:ru).digest)
    end
  end

  it "gives different digests to locales with manuals of their own" do
    expect(described_class.for(:pl).digest).not_to eq(described_class.for(:ru).digest)
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
