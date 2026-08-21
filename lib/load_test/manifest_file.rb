# Extracted from the rake task, not because the task was long, but because
# this is exactly the part Task 5's console screen must reproduce -- and
# exactly where a permission/ordering bug would leak live credentials. One
# implementation is the only way both callers get the same guarantee instead
# of the console screen re-deriving (and possibly dropping) it.
module LoadTest
  module ManifestFile
    class UnsafePath < StandardError; end

    # This repository is public. A manifest written under Rails.root is one
    # `git add -A` away from committing live production credentials and every
    # level's answer codes -- refuse outright rather than relying on a
    # .gitignore entry someone could delete, or fail to add for a new path.
    def self.write!(manifest, path:)
      full_path = File.expand_path(path)
      root      = File.expand_path(Rails.root)

      if full_path == root || full_path.start_with?("#{root}#{File::SEPARATOR}")
        raise UnsafePath,
              "refusing to write a load-test manifest under Rails.root (#{full_path})"
      end

      # 0600 from the instant the file exists, not after: File.write followed
      # by a separate File.chmod creates the file at the process umask
      # (typically 0644) and holds live captain credentials plus every
      # level's answer codes in a world-readable file until the chmod runs --
      # and if the path already exists and is owned by someone else, the
      # credentials are written and THEN chmod raises. File::EXCL additionally
      # refuses to follow a symlink or silently overwrite a stale manifest
      # sitting at a predictable /tmp path from an earlier run.
      File.open(full_path, File::WRONLY | File::CREAT | File::EXCL, 0600) do |f|
        f.write(JSON.pretty_generate(manifest))
      end

      full_path
    end
  end
end
