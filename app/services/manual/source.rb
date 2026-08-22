# app/services/manual/source.rb
#
# WHICH manual document a reader gets, and what it hashes to.
#
# This is the seam sub-project B replaces. Today it answers from the files that
# ship in the image; when superadmin-run translation lands, it will look for an
# approved translation row first and fall through to here. Nothing above it --
# controller, cache, renderer, view -- knows the difference, which is the whole
# reason it exists as its own object rather than two lines in the controller.
#
# locale_used is not a detail. Five of the seven registered locales have no
# manual, and a reader who asked for Polish and got Russian is entitled to be
# told that happened rather than left to conclude the site is broken.
#
# Trust class: what this returns is rendered with `raw` in
# app/views/manual/show.html.erb. That is safe only because these are
# repository-authored files, reviewed in a pull request before they ship in
# the image -- kramdown's GFM parser passes raw HTML straight through
# unescaped, so this document is a template rendered into every visitor's
# browser, not inert text. A database-backed translation is a DIFFERENT trust
# class -- user-influenced-at-best content a superadmin approved, not a PR
# reviewer -- and sub-project B has to re-decide the `raw` call when it
# replaces this seam, not inherit it from here.
require "digest"

module Manual
  class Source
    DIRECTORY = Rails.root.join("docs/manual")
    FALLBACK_LOCALE = :ru

    Document = Struct.new(:markdown, :locale_used, :digest, :keyword_init => true)

    class Missing < StandardError; end

    def self.for(locale)
      locale_used = available?(locale) ? locale.to_sym : FALLBACK_LOCALE
      path = path_for(locale_used)

      unless path.exist?
        raise Missing, <<~MESSAGE
          No manual at #{path}.

          In a container this means docs/manual was not copied into the image:
          .dockerignore excludes docs, and the `!docs/manual` re-include is what
          puts it back. See the design doc, §6.
        MESSAGE
      end

      markdown = path.read
      Document.new(
        :markdown => markdown,
        :locale_used => locale_used,
        :digest => Digest::SHA256.hexdigest(markdown)
      )
    end

    def self.available?(locale)
      path_for(locale).exist?
    end

    # Which locales have a manual of their own rather than falling back.
    #
    # Manual::Renderer asks, so that a ](xx.md) link inside a manual becomes
    # this app's own /manual?locale=xx instead of a GitHub URL. That is a
    # question about which manuals THIS APP SERVES, which is this object's
    # business and nobody else's -- the alternative, a hard-coded pair in the
    # renderer, was already stale the day a third translation landed.
    #
    # It matters more for sub-project B than for today: when a translation
    # lives in the database rather than in a file, this method is what teaches
    # the link pass that the locale is now served here.
    #
    # Filtered against the registered locales on purpose. docs/manual also
    # holds deployment.*.md and performance.*.md, whose basenames are not
    # locales and which this app does not serve.
    def self.available_locales
      registered = I18n.available_locales.map(&:to_s)

      DIRECTORY.glob("*.md")
               .map { |path| path.basename(".md").to_s }
               .select { |name| registered.include?(name) }
               .map(&:to_sym)
               .sort
    end

    def self.path_for(locale)
      DIRECTORY.join("#{locale}.md")
    end
    private_class_method :path_for
  end
end
