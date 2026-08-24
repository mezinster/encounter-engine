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
      File.write(destination, File.read(File.join(@docs_root, relative_path)))
    end
  end
end
