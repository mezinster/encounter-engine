require "rails_helper"
require "tmpdir"

# Stylesheets and scripts are plain files under public/ with no asset
# pipeline, linked by fixed URLs. With no Cache-Control a browser caches them
# heuristically, so after a deploy a returning visitor could pair new HTML
# with an old screens.css -- seen on 2026-10-01: the new home page, unstyled.
# versioned_asset puts the file's content digest in the URL, so the URL
# changes exactly when the file does.
describe ApplicationHelper, "#versioned_asset", type: :helper do
  around do |example|
    Dir.mktmpdir do |dir|
      @public = Pathname(dir)
      FileUtils.mkdir_p(@public.join("stylesheets"))
      example.run
    end
  end

  # Mocks are not available yet inside `around`, so the stub lives here.
  before { allow(Rails).to receive(:public_path).and_return(@public) }

  def write(content)
    path = @public.join("stylesheets/site.css")
    path.write(content)
    # The memo is keyed on mtime; make sure a rewrite is seen as a new file
    # even when both writes land in the same second.
    File.utime(Time.now, Time.now + @bump = (@bump || 0) + 10, path)
  end

  it "appends a short digest of the file's content" do
    write("body { color: red }")
    digest = Digest::SHA256.hexdigest("body { color: red }")[0, 12]

    expect(helper.versioned_asset("/stylesheets/site.css")).to eq("/stylesheets/site.css?v=#{digest}")
  end

  it "changes the URL when the file changes, and only then" do
    write("a {}")
    first = helper.versioned_asset("/stylesheets/site.css")
    expect(helper.versioned_asset("/stylesheets/site.css")).to eq(first)

    write("b {}")
    expect(helper.versioned_asset("/stylesheets/site.css")).not_to eq(first)
  end

  # A typo should cost one 404 on one asset, never a 500 on every page.
  it "returns the plain path for a file that does not exist" do
    expect(helper.versioned_asset("/stylesheets/missing.css")).to eq("/stylesheets/missing.css")
  end
end
