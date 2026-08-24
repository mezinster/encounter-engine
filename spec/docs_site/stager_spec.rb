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
    it "stages every manual, plus the two named extras and the generated landing page" do
      stage do |stager, _out|
        expect(stager.call).to eq(
          [
            "index.md",
            "manual/en.md",
            "manual/ru.md",
            "manual/uk.md",
            "perf/README.md",
            "runbooks/restore.md"
          ]
        )
      end
    end

    it "does not stage a file from a directory the allowlist never names" do
      stage do |stager, out|
        stager.call
        expect(File.exist?(File.join(out, "secret/findings.md"))).to be false
      end
    end

    # The sharper property, and the one the secret/ example above cannot show:
    # EXTRA_FILES names ONE file out of docs/runbooks/, which really holds four
    # -- including vm-scaling-setup.md, the Azure OIDC identity runbook. A
    # regression widening EXTRA_FILES into Dir.glob("runbooks/*.md") passes
    # every other example in this file.
    it "does not stage an unnamed sibling of a file the allowlist does name" do
      stage do |stager, out|
        expect(stager.call).not_to include("runbooks/internal.md")
        expect(File.exist?(File.join(out, "runbooks/internal.md"))).to be false
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

  describe "the generated landing page" do
    # Without it the advertised site root serves Material's 404 page: MkDocs
    # synthesises no index and --strict does not warn about the absence.
    it "writes an index.md the sources do not contain" do
      stage do |stager, out|
        stager.call

        expect(File.exist?(File.join(out, "index.md"))).to be true
        expect(File.exist?(File.join(FIXTURE_DOCS, "index.md"))).to be false
      end
    end

    it "lists every staged file, under its group heading, by its own endonym" do
      stage do |stager, out|
        stager.call
        index = File.read(File.join(out, "index.md"), :encoding => "UTF-8")

        expect(index).to include("## Руководство пользователя")
        expect(index).to include("- [Русский](manual/ru.md)")
        expect(index).to include("- [English](manual/en.md)")
        expect(index).to include("- [Українська](manual/uk.md)")
        expect(index).to include("## Нагрузочное тестирование / Performance")
        expect(index).to include("- [Records](perf/README.md)")
        expect(index).to include("## Runbooks")
        expect(index).to include("- [Restoring the database](runbooks/restore.md)")
      end
    end

    it "does not invent an entry for a file that was not staged" do
      stage do |stager, out|
        stager.call

        expect(File.read(File.join(out, "index.md"), :encoding => "UTF-8"))
          .not_to include("manual/be.md")
      end
    end

    # This is what stops a new manual from being staged by the glob and then
    # silently missing from the site's only table of contents.
    it "refuses to stage a file it has no label for" do
      Dir.mktmpdir("docs-site-src") do |src|
        FileUtils.mkdir_p(File.join(src, "manual"))
        FileUtils.mkdir_p(File.join(src, "runbooks"))
        FileUtils.mkdir_p(File.join(src, "perf"))
        File.write(File.join(src, "runbooks/restore.md"), "# R\n")
        File.write(File.join(src, "perf/README.md"), "# P\n")
        File.write(File.join(src, "manual/zz.md"), "# Z\n")

        stage(:docs_root => src) do |stager, _out|
          expect { stager.call }
            .to raise_error(DocsSite::Stager::MissingLabelError, %r{manual/zz\.md})
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

    # Renamed onto "be.md" rather than an invented name: every staged file needs
    # a LABELS entry now, so renaming to something LABELS has never heard of
    # would raise MissingLabelError before the closure check ever ran, and this
    # example would stop testing what it is named for.
    it "refuses a link broken by a rename" do
      Dir.mktmpdir("docs-site-src") do |src|
        FileUtils.cp_r(File.join(FIXTURE_DOCS, "."), src)
        File.rename(File.join(src, "manual/en.md"), File.join(src, "manual/be.md"))

        stage(:docs_root => src) do |stager, _out|
          expect { stager.call }
            .to raise_error(DocsSite::Stager::ClosureError, %r{en\.md})
        end
      end
    end

    it "counts the generated landing page as published, so a link to it resolves" do
      Dir.mktmpdir("docs-site-src") do |src|
        FileUtils.cp_r(File.join(FIXTURE_DOCS, "."), src)
        File.write(
          File.join(src, "manual/en.md"),
          File.read(File.join(src, "manual/en.md"), :encoding => "UTF-8") +
            "\nBack to [the index](../index.md).\n"
        )

        stage(:docs_root => src) do |stager, _out|
          expect { stager.call }.not_to raise_error
        end
      end
    end

    # index.md exists in no source directory, so a check rooted at docs_root
    # could not see its links at all. This is the only content in the system
    # whose links the stager writes itself.
    it "scans the generated landing page, not only the copied sources" do
      stager_with_a_broken_index = Class.new(described_class) do
        private

        def index_markdown
          "# encounter-engine\n\n- [findings](secret/findings.md)\n"
        end
      end

      Dir.mktmpdir("docs-site-out") do |out|
        stager = stager_with_a_broken_index.new(:docs_root => FIXTURE_DOCS, :out_root => out)

        expect { stager.call }
          .to raise_error(DocsSite::Stager::ClosureError, %r{index\.md -> secret/findings\.md})
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
