require "rails_helper"
require "rake"

describe "game_files rake tasks" do
  before(:all) do
    Rake.application.rake_require("tasks/game_files", [ Rails.root.join("lib").to_s ])
    Rake::Task.define_task(:environment)
  end

  before(:each) do
    Rake::Task.tasks.each(&:reenable)
    @game = create_game
  end

  describe "game_files:regenerate_variants" do
    it "rewrites derived_byte_size for a row left at zero" do
      # This is the ONLY reconciliation path for an undercount: phase 2A measures
      # variants after commit, so a process killed in between leaves a row at 0
      # that nothing else revisits.
      file = GameFileUpload.new(@game, fixture_upload("photo.jpg"), create_user).call

      # The true figure, read straight from the variants' own attached images
      # BEFORE the column is zeroed -- not a hardcoded number, which libvips
      # could shift by a byte on its next encoder update, and not `be > 0`,
      # which passed even while the task's own arithmetic double-counted the
      # canonical bytes instead of measuring the derivatives.
      true_derived_size = [ file.web_variant, file.thumb_variant ].compact.sum { |v| v.image.blob.byte_size }
      file.update_column(:derived_byte_size, 0)

      Rake::Task["game_files:regenerate_variants"].invoke

      expect(file.reload.derived_byte_size).to eq(true_derived_size)
    end

    it "leaves a PDF at zero, because a PDF has no variants" do
      # A smoke check, not a guard: the column is already 0 before the task
      # runs, and the task's `rescue StandardError` swallows anything the block
      # raises, so this stays green even with `raise "MUTATION"` as the first
      # line of the find_each body (verified). The example above is the one
      # that carries the weight -- it pins the exact regenerated figure and
      # fails if the arithmetic or the iteration is wrong.
      file = GameFileUpload.new(@game, fixture_upload("map.pdf"), create_user).call

      Rake::Task["game_files:regenerate_variants"].invoke

      expect(file.reload.derived_byte_size).to eq(0)
    end
  end

  describe "game_files:purge_orphans" do
    it "purges a blob attached to nothing" do
      ActiveStorage::Blob.create_and_upload!(
        :io => StringIO.new("orphan"), :filename => "orphan.bin",
        :content_type => "application/octet-stream"
      )

      expect { Rake::Task["game_files:purge_orphans"].invoke }
        .to change { ActiveStorage::Blob.unattached.count }.to(0)
    end

    it "leaves an attached blob alone" do
      # Without this the task could satisfy its own test by purging everything --
      # EXCEPT it can't, and that's the point of the second example below.
      #
      # ActiveStorage::Blob#purge is:
      #
      #   def purge
      #     destroy
      #     delete if previously_persisted?
      #   rescue ActiveRecord::InvalidForeignKey
      #   end
      #
      # and db/schema.rb carries a real foreign key from active_storage_attachments
      # to active_storage_blobs. For an attached blob, `destroy` raises
      # InvalidForeignKey, the rescue swallows it, and `delete` is never reached --
      # so an attached blob (and its file on disk) survives `purge` whether or not
      # the query was scoped to `.unattached` first. Verified: mutating this task's
      # body to `ActiveStorage::Blob.find_each(&:purge)` (purging EVERY blob, not
      # just unattached ones) still passes this exact example -- the database's own
      # FK does the protecting, not the code under test. Kept as a smoke check, but
      # the example below is what can actually fail if the scope is dropped.
      file = GameFileUpload.new(@game, fixture_upload("photo.jpg"), create_user).call

      Rake::Task["game_files:purge_orphans"].invoke

      expect(file.reload.file).to be_attached
    end

    it "iterates ActiveStorage::Blob.unattached, not every blob" do
      # The real discriminator for the mutation described above: stub .unattached
      # to keep returning the SAME relation object, then require `find_each` to be
      # called on THAT relation. `ActiveStorage::Blob.find_each(&:purge)` calls
      # find_each on the bare class, never touching the stubbed relation, so this
      # fails under that mutation even though the outcome-based example above does
      # not (verified: reverting to `ActiveStorage::Blob.unattached.find_each` --
      # the shipped code -- makes it pass again; see task 5's review notes for the
      # actual failure output).
      scope = ActiveStorage::Blob.unattached
      allow(ActiveStorage::Blob).to receive(:unattached).and_return(scope)
      expect(scope).to receive(:find_each).and_call_original

      Rake::Task["game_files:purge_orphans"].invoke
    end
  end
end
