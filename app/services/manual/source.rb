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

    def self.path_for(locale)
      DIRECTORY.join("#{locale}.md")
    end
    private_class_method :path_for
  end
end
