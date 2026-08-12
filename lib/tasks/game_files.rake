# -*- encoding : utf-8 -*-
namespace :game_files do
  desc "Purge Active Storage blobs attached to nothing"
  #
  # DELIBERATELY NO AGE CUTOFF, unlike Rails' own recommended
  # `ActiveStorage::Blob.unattached.where(created_at: ..2.days.ago).find_each`.
  # That cutoff exists for apps with direct uploads, where a blob is created by
  # the browser minutes or hours before the form that attaches it is submitted,
  # so a young unattached blob is normally an upload still in flight.
  #
  # This app has no direct uploads. The only writer is GameFileUpload#call,
  # where GameFile#file.attach and the row's save happen inside one transaction
  # (@game.with_lock's), so the blob row and its attachment row become visible
  # to any other connection together or not at all -- no other connection can
  # observe a live upload as unattached. Adding the cutoff would instead delay
  # reclaiming genuine orphans by two days, and orphans are the reason this
  # task exists: the destroy-and-reject paths in GameFileUpload leave them
  # behind precisely when the disk is already under pressure.
  #
  # NOT PROVEN UNDER CONCURRENCY. The reasoning above is a read of the upload
  # path, not an experiment -- nobody has run this task against a server taking
  # real simultaneous uploads. If a second writer is ever added (a direct-upload
  # endpoint, an importer, an API), re-derive this before trusting it; the
  # failure mode is a purged blob under an author's feet mid-upload, which is
  # silent.
  task :purge_orphans => :environment do
    count = ActiveStorage::Blob.unattached.count
    ActiveStorage::Blob.unattached.find_each(&:purge)
    puts "purged #{count} unattached blob(s)"
  end

  desc "Rebuild every file's variants and rewrite derived_byte_size"
  task :regenerate_variants => :environment do
    # v.image.blob, not v.blob -- see the comment on GameFileUpload#measure_derived!,
    # which this mirrors. v.blob is the SOURCE blob a VariantWithRecord was built
    # from, not the derivative's own bytes; v.image.blob is the tracked variant's
    # actual attached image.
    GameFile.find_each do |file|
      derived = [ file.web_variant, file.thumb_variant ].compact
      file.update_column(:derived_byte_size, derived.sum { |v| v.image.blob.byte_size })
    rescue StandardError => e
      # One bad file must not stop the reconciliation of every other.
      warn "#{file.id} #{file.filename}: #{e.class}"
    end
    puts "regenerated variants for #{GameFile.count} file(s)"
  end
end
