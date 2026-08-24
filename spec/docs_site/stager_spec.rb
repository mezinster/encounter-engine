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

  describe "the machine-translation banner" do
    it "renders the invisible HTML comment as a visible admonition, in the page's own language" do
      stage do |stager, out|
        stager.call
        uk = File.read(File.join(out, "manual/uk.md"))

        expect(uk).to include('!!! warning "Машинний переклад"')
        expect(uk).to include("`ru.md`")
        expect(uk).to include("2026-08-22")
      end
    end

    it "puts the banner after the heading, so the page still has its title first" do
      stage do |stager, out|
        stager.call
        lines = File.read(File.join(out, "manual/uk.md")).lines.map(&:chomp)

        expect(lines[0]).to start_with("<!--")
        expect(lines[1]).to eq("# Посібник")
        expect(lines[3]).to start_with("!!! warning")
      end
    end

    it "leaves a file without the comment byte-identical" do
      stage do |stager, out|
        stager.call

        expect(File.read(File.join(out, "manual/ru.md")))
          .to eq(File.read(File.join(FIXTURE_DOCS, "manual/ru.md")))
      end
    end

    it "refuses to publish a machine-translated locale it has no banner for" do
      Dir.mktmpdir("docs-site-src") do |src|
        FileUtils.mkdir_p(File.join(src, "manual"))
        FileUtils.mkdir_p(File.join(src, "runbooks"))
        FileUtils.mkdir_p(File.join(src, "perf"))
        File.write(File.join(src, "runbooks/restore.md"), "# R\n")
        File.write(File.join(src, "perf/README.md"), "# P\n")
        File.write(
          File.join(src, "manual/zz.md"),
          "<!-- Machine-translated from ru.md on 2026-08-22. Not reviewed by a native speaker. -->\n# Z\n"
        )

        stage(:docs_root => src) do |stager, _out|
          expect { stager.call }
            .to raise_error(DocsSite::Stager::MissingBannerError, /zz/)
        end
      end
    end
  end

  describe "the closure check" do
    it "accepts a set whose links all resolve inside it" do
      stage do |stager, _out|
        expect { stager.call }.not_to raise_error
      end
    end

    it "refuses a link pointing at a document that is not published" do
      Dir.mktmpdir("docs-site-src") do |src|
        FileUtils.cp_r(File.join(FIXTURE_DOCS, "."), src)
        File.write(
          File.join(src, "manual/en.md"),
          File.read(File.join(src, "manual/en.md")) +
            "\nSee [the findings](../secret/findings.md).\n"
        )

        stage(:docs_root => src) do |stager, _out|
          expect { stager.call }
            .to raise_error(DocsSite::Stager::ClosureError, %r{secret/findings\.md})
        end
      end
    end

    it "refuses a link broken by a rename" do
      Dir.mktmpdir("docs-site-src") do |src|
        FileUtils.cp_r(File.join(FIXTURE_DOCS, "."), src)
        File.rename(File.join(src, "manual/en.md"), File.join(src, "manual/eng.md"))

        stage(:docs_root => src) do |stager, _out|
          expect { stager.call }
            .to raise_error(DocsSite::Stager::ClosureError, %r{en\.md})
        end
      end
    end

    it "ignores absolute links and bare anchors, which are not its business" do
      Dir.mktmpdir("docs-site-src") do |src|
        FileUtils.cp_r(File.join(FIXTURE_DOCS, "."), src)
        # The GitHub link is the load-bearing case: it ends in ".md" and starts
        # with a letter, so a check that only excluded ":" as a leading
        # character would report it as dangling and fail every real build.
        File.write(
          File.join(src, "manual/en.md"),
          "# Manual\n\n" \
          "[site](https://game.mezin.eu/) " \
          "[spec](https://github.com/mezinster/encounter-engine/blob/master/docs/security/x.md) " \
          "[top](#manual) [ru](ru.md)\n"
        )

        stage(:docs_root => src) do |stager, _out|
          expect { stager.call }.not_to raise_error
        end
      end
    end
  end
end
