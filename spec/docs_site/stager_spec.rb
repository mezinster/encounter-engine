# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require_relative "../../docs-site/stager"

RSpec.describe DocsSite::Stager do
  # The fixture tree stands in for docs/. Running against the real docs/ would
  # mean an ordinary edit to a manual could redden the default rspec run --
  # the exact failure CLAUDE.md records against renderer_spec.rb's file list.
  FIXTURE_DOCS = File.expand_path("../fixtures/docs_site", __dir__)

  # Every example gets its own output directory and removes it afterwards.
  def stage(docs_root: FIXTURE_DOCS)
    Dir.mktmpdir("docs-site-spec") do |out|
      yield described_class.new(:docs_root => docs_root, :out_root => out), out
    end
  end

  describe "the allowlist" do
    it "stages every manual, plus the two named extras" do
      stage do |stager, _out|
        expect(stager.call).to eq(
          [
            "manual/en.md",
            "manual/ru.md",
            "manual/uk.md",
            "perf/README.md",
            "runbooks/restore.md"
          ]
        )
      end
    end

    it "does not stage a file outside the allowlist" do
      stage do |stager, out|
        stager.call
        expect(File.exist?(File.join(out, "secret/findings.md"))).to be false
      end
    end

    it "preserves each file's path relative to docs/, which is what keeps links working" do
      stage do |stager, out|
        stager.call
        expect(File.exist?(File.join(out, "manual/ru.md"))).to be true
        expect(File.exist?(File.join(out, "runbooks/restore.md"))).to be true
      end
    end
  end
end
