# -*- encoding : utf-8 -*-
namespace :game_files do
  desc "Purge Active Storage blobs attached to nothing"
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
