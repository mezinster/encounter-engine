# frozen_string_literal: true

# Stages the publishable subset of docs/ into a directory MkDocs can build.
#
# Pure Ruby, no Rails, no network -- the same shape as ops/vmscale/policy.rb,
# and for the same reason: a function from a tree of files to a tree of files
# is testable from fixtures, and bin/stage-docs-site is the only thing with
# side effects on the real repository.
#
# The one rule this file exists to enforce is that docs/ is NOT publishable
# wholesale. docs/superpowers/ and docs/security/ stay unpublished, and two
# independent checks stand between "someone adds a helpful link" and one of
# them acquiring a public, indexed URL:
#
#   1. #assert_closed here, which scans the staged tree for relative .md links
#      and fails on any target outside the staged set. It is a regex, so it is
#      the cheaper and the more easily fooled of the two.
#   2. `mkdocs build --strict`, whose validation.links.not_found resolves every
#      link MkDocs itself parses -- including titled links such as
#      `](x.md "t")` that RELATIVE_LINK's own pattern does not match.
#
# Neither subsumes the other: (1) runs before MkDocs and knows what the
# allowlist is, so it can tell "outside the published set" from "broken"; (2)
# parses markdown properly rather than by regex. Do not delete one because the
# other exists.
require "fileutils"
require "set"

module DocsSite
  class Stager
    class MissingBannerError < StandardError; end
    class MissingLabelError < StandardError; end
    class ClosureError < StandardError; end

    # A markdown link target, with any #fragment split off.
    #
    # The lookahead is doing real work: excluding ":" from a leading character
    # class is NOT enough, because "https://github.com/x/y/blob/master/z.md"
    # begins with "h" and ends in ".md", so it would sail through as a relative
    # link and be reported as dangling. Schemes and absolute paths are rejected
    # as a whole, up front.
    RELATIVE_LINK = %r{\]\(\s*(?!\w+://|/)(?<target>[^)\s#]+\.md)(?:\#[^)\s]*)?\s*\)}

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
    # safe here -- but "safe" means *staged*, not *published*: a new manual is
    # picked up automatically and then the build FAILS until somebody adds it
    # to LABELS below and to mkdocs.yml's nav:. That gate is deliberate. A glob
    # with no gate would be a directory that publishes whatever lands in it;
    # the two hand-maintained lists are what turn "it appeared in docs/manual"
    # into "a human decided it goes on the public web."
    MANUAL_GLOB = "manual/*.md"

    # Everything else is named one file at a time, so that widening the
    # published set is a visible diff line rather than a side effect.
    EXTRA_FILES = %w[runbooks/restore.md perf/README.md].freeze

    # The generated landing page. MkDocs synthesises no index of its own and
    # --strict does not warn about the absence, so without this the advertised
    # site root serves Material's 404 page. Written into @out_root only --
    # docs/ itself is never touched.
    INDEX_FILE = "index.md"

    # Display label and group heading per published file, in the order the
    # landing page and mkdocs.yml's nav: list them. The labels are the endonyms
    # nav: uses, so the two surfaces read the same.
    #
    # The *membership* of the landing page is derived from #sources rather than
    # from this hash -- a second hand-written list of what is published could
    # drift from what is actually staged. This hash only answers "what is that
    # file called in Russian", and a staged file it has no answer for raises,
    # the same way an unbannered machine translation does.
    LABELS = {
      "manual/ru.md" => ["Руководство пользователя", "Русский"],
      "manual/en.md" => ["Руководство пользователя", "English"],
      "manual/uk.md" => ["Руководство пользователя", "Українська"],
      "manual/be.md" => ["Руководство пользователя", "Беларуская"],
      "manual/pl.md" => ["Руководство пользователя", "Polski"],
      "manual/tr.md" => ["Руководство пользователя", "Türkçe"],
      "manual/ka.md" => ["Руководство пользователя", "ქართული"],
      "manual/deployment.ru.md" => ["Установка / Installation", "Русский"],
      "manual/deployment.en.md" => ["Установка / Installation", "English"],
      "manual/performance.ru.md" => ["Нагрузочное тестирование / Performance", "Русский"],
      "manual/performance.en.md" => ["Нагрузочное тестирование / Performance", "English"],
      "perf/README.md" => ["Нагрузочное тестирование / Performance", "Records"],
      "runbooks/restore.md" => ["Runbooks", "Restoring the database"]
    }.freeze

    def initialize(docs_root:, out_root:)
      @docs_root = File.expand_path(docs_root)
      @out_root = File.expand_path(out_root)
    end

    # Relative paths of the source files that will be copied, sorted.
    def sources
      (Dir.glob(MANUAL_GLOB, :base => @docs_root) + EXTRA_FILES).uniq.sort
    end

    # Everything the build directory ends up holding: the copied sources plus
    # the landing page, which has no source file at all.
    def staged
      (sources + [INDEX_FILE]).sort
    end

    def call
      FileUtils.rm_rf(@out_root)
      sources.each { |relative_path| stage(relative_path) }
      write_index
      assert_closed
      staged
    end

    private

    # Every File.read in this file names its encoding, and that is not
    # decoration: File.read defaults to the locale's external encoding, so under
    # LANG=C these files are read as US-ASCII and the first Cyrillic byte raises
    # `invalid byte sequence in US-ASCII` -- from the regex scan, some way from
    # the read that actually caused it. CI sets LANG=C.UTF-8 today, but ci.yml's
    # RSpec job already runs inside a `container:` and matching that here is a
    # plausible future edit.
    def stage(relative_path)
      destination = File.join(@out_root, relative_path)
      FileUtils.mkdir_p(File.dirname(destination))
      File.write(
        destination,
        with_banner(relative_path, File.read(File.join(@docs_root, relative_path), :encoding => "UTF-8"))
      )
    end

    def write_index
      File.write(File.join(@out_root, INDEX_FILE), index_markdown)
    end

    # A table of contents and nothing else: the site's own title, one heading
    # per group, one bullet per published file. Prose here would be a fourth
    # copy of what the manuals already say, maintained by nobody.
    def index_markdown
      unlabelled = sources.reject { |relative_path| LABELS.key?(relative_path) }
      unless unlabelled.empty?
        raise MissingLabelError,
              "staged for publication with no entry in DocsSite::Stager::LABELS, so the " \
              "landing page cannot list it: #{unlabelled.join(", ")}. Add it to LABELS " \
              "and to docs-site/mkdocs.yml's nav: -- mkdocs --strict fails on the second " \
              "of those anyway, and a page in neither list is a page nobody finds."
      end

      # Ordered by LABELS, filtered to what was actually staged: the order is
      # editorial (Русский first, not "be" first), the membership is not.
      published = sources.to_set
      groups = LABELS.each_with_object({}) do |(relative_path, (group, label)), accumulator|
        next unless published.include?(relative_path)

        (accumulator[group] ||= []) << "- [#{label}](#{relative_path})"
      end

      sections = groups.map { |group, links| "## #{group}\n\n#{links.join("\n")}\n" }
      "# encounter-engine\n\n#{sections.join("\n")}"
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

    # Every relative .md link in the published set must resolve to something
    # else in the published set. Anything else is either a link onto a document
    # this repository deliberately does not publish, or a link broken by a
    # rename -- and the right response to both is a red build, not a quiet
    # widening of the allowlist.
    #
    # It reads the STAGED tree, not @docs_root, and that is not interchangeable:
    # index.md is generated here and exists in no source directory, so a check
    # rooted at @docs_root structurally could not see its links -- the only
    # links in the system this repository writes itself. Reading the staged tree
    # also means the check sees exactly the bytes MkDocs will render. Do not
    # "simplify" it back to the sources.
    def assert_closed
      published = staged.to_set
      dangling = []

      staged.each do |relative_path|
        markdown = File.read(File.join(@out_root, relative_path), :encoding => "UTF-8")

        # RELATIVE_LINK has exactly one capturing group, so scan yields
        # one-element arrays; destructuring reads more plainly than
        # Regexp.last_match inside a block.
        markdown.scan(RELATIVE_LINK).each do |(target)|
          # Resolved as an absolute path rooted at "/" so that "../" is
          # normalised by expand_path, then stripped back to a docs-relative
          # path for comparison. Doing this on real filesystem paths would
          # resolve against the machine instead of against the published set.
          resolved = File.expand_path(target, File.dirname("/#{relative_path}")).delete_prefix("/")
          dangling << "#{relative_path} -> #{target}" unless published.include?(resolved)
        end
      end

      return if dangling.empty?

      raise ClosureError,
            "these links leave the published set:\n  #{dangling.join("\n  ")}\n" \
            "Either the target belongs on the site (add it to EXTRA_FILES, deliberately), " \
            "or the link is wrong."
    end
  end
end
