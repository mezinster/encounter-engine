# frozen_string_literal: true

# Stages the publishable subset of docs/ into a directory MkDocs can build.
#
# Pure Ruby, no Rails, no network -- the same shape as ops/vmscale/policy.rb,
# and for the same reason: a function from a tree of files to a tree of files
# is testable from fixtures, and bin/stage-docs-site is the only thing with
# side effects on the real repository.
#
# The one rule this file exists to enforce is that docs/ is NOT publishable
# wholesale. docs/superpowers/ and docs/security/ stay unpublished, and the
# check in #assert_closed is what stops a link from quietly dragging one of
# them onto the public web.
require "fileutils"

module DocsSite
  class Stager
    class MissingBannerError < StandardError; end

    # The uniform first line of every machine-translated manual. It names both
    # the source and the date, so the banner is derived rather than maintained:
    # a locale that gets reviewed by a human loses its banner by having this
    # comment deleted, in the same commit as the review.
    MT_COMMENT = /
      \A<!--\s*Machine-translated\ from\ (?<source>\S+)\ on\ (?<date>\d{4}-\d{2}-\d{2})\.
      \s*Not\ reviewed\ by\ a\ native\ speaker\.\s*-->
    /x

    # [title, body] per locale. These strings are themselves machine-produced,
    # which is self-consistent rather than ironic: they say so.
    #
    # The Turkish entry follows CLAUDE.md's rule for agglutinative languages --
    # the case suffix lands on "dosya" (file), never on the interpolated
    # filename, because which suffix is correct depends on the value's final
    # vowel.
    BANNERS = {
      "uk" => [
        "Машинний переклад",
        "Цю сторінку перекладено машинно з `%{source}` %{date}. Її не перевіряв носій мови."
      ],
      "be" => [
        "Машынны пераклад",
        "Гэтая старонка перакладзена машынна з `%{source}` %{date}. Яе не правяраў носьбіт мовы."
      ],
      "pl" => [
        "Tłumaczenie maszynowe",
        "Ta strona została przetłumaczona maszynowo z `%{source}` %{date}. Nie sprawdził jej native speaker."
      ],
      "tr" => [
        "Makine çevirisi",
        "Bu sayfa %{date} tarihinde `%{source}` dosyasından makineyle çevrildi. Ana dili konuşan biri tarafından kontrol edilmedi."
      ],
      "ka" => [
        "მანქანური თარგმანი",
        "ეს გვერდი მანქანურად ითარგმნა `%{source}`-დან %{date}. მშობლიური ენის მატარებელს არ შეუმოწმებია."
      ]
    }.freeze

    # docs/manual is already the vetted-public directory: it is the one part of
    # docs/ that .dockerignore re-includes into the shipped image. So a glob is
    # safe here, and a new translation publishes itself the day it lands.
    MANUAL_GLOB = "manual/*.md"

    # Everything else is named one file at a time, so that widening the
    # published set is a visible diff line rather than a side effect.
    EXTRA_FILES = %w[runbooks/restore.md perf/README.md].freeze

    def initialize(docs_root:, out_root:)
      @docs_root = File.expand_path(docs_root)
      @out_root = File.expand_path(out_root)
    end

    # Relative paths of everything that will be published, sorted.
    def sources
      (Dir.glob(MANUAL_GLOB, :base => @docs_root) + EXTRA_FILES).uniq.sort
    end

    def call
      FileUtils.rm_rf(@out_root)
      sources.each { |relative_path| stage(relative_path) }
      sources
    end

    private

    def stage(relative_path)
      destination = File.join(@out_root, relative_path)
      FileUtils.mkdir_p(File.dirname(destination))
      File.write(destination, with_banner(relative_path, File.read(File.join(@docs_root, relative_path))))
    end

    # Additive and derived: files with no declaration pass through untouched,
    # and nothing on disk is modified.
    def with_banner(relative_path, markdown)
      declaration = MT_COMMENT.match(markdown)
      return markdown if declaration.nil?

      locale = File.basename(relative_path, ".md")
      title, body = BANNERS[locale]
      if title.nil?
        raise MissingBannerError,
              "#{relative_path} declares a machine translation but DocsSite::Stager::BANNERS " \
              "has no text for locale #{locale.inspect}. Add it rather than publishing an " \
              "unmarked machine translation."
      end

      admonition = format(
        "!!! warning \"%<title>s\"\n\n    %<body>s\n",
        :title => title,
        :body => body % { :source => declaration[:source], :date => declaration[:date] }
      )

      insert_after_heading(markdown, admonition)
    end

    # After the H1, so the page keeps its title as the first thing rendered.
    def insert_after_heading(markdown, admonition)
      lines = markdown.lines
      heading = lines.index { |line| line.start_with?("# ") }
      return "#{admonition}\n#{markdown}" if heading.nil?

      lines.insert(heading + 1, "\n#{admonition}").join
    end
  end
end
