require "rails_helper"
require "tmpdir"

describe LoadTest::ManifestFile do
  let(:manifest) { { :cohort_id => "lt-a", :teams => [ { :email => "a@loadtest.invalid" } ] } }

  around do |example|
    Dir.mktmpdir("load-test-manifest-spec") { |dir| @tmp_dir = dir; example.run }
  end

  def tmp_path(name = "manifest.json")
    File.join(@tmp_dir, name)
  end

  it "writes the manifest as pretty JSON" do
    path = described_class.write!(manifest, :path => tmp_path)

    expect(JSON.parse(File.read(path))).to eq(JSON.parse(manifest.to_json))
  end

  it "returns the path it wrote" do
    path = described_class.write!(manifest, :path => tmp_path)

    expect(path).to eq(File.expand_path(tmp_path))
  end

  # 0600 from the moment the file exists, not File.write followed by a
  # separate File.chmod -- that sequence creates the file at the process
  # umask (typically 0644) and holds live credentials in a world-readable
  # file for the gap between the two calls.
  it "creates the file at mode 0600, never wider" do
    path = described_class.write!(manifest, :path => tmp_path)

    expect(File.stat(path).mode & 0777).to eq(0600)
  end

  # File::EXCL: refuses to follow a symlink or silently overwrite a stale
  # manifest sitting at a predictable path from an earlier run -- credentials
  # from two different cohorts must never land in the same file.
  it "refuses to overwrite a path that already exists" do
    path = tmp_path
    File.write(path, "stale content from an earlier run")

    expect { described_class.write!(manifest, :path => path) }
      .to raise_error(Errno::EEXIST)
    expect(File.read(path)).to eq("stale content from an earlier run")
  end

  # This repository is public. A manifest carries live account credentials
  # and every level's answer codes -- refuse a path under Rails.root outright
  # rather than relying on a .gitignore entry someone could delete or fail to
  # add for a new path.
  it "refuses a path under Rails.root" do
    path = Rails.root.join("tmp", "manifest.json").to_s

    expect { described_class.write!(manifest, :path => path) }
      .to raise_error(LoadTest::ManifestFile::UnsafePath)
    expect(File).not_to exist(path)
  end

  it "refuses Rails.root itself" do
    expect { described_class.write!(manifest, :path => Rails.root.to_s) }
      .to raise_error(LoadTest::ManifestFile::UnsafePath)
  end
end
