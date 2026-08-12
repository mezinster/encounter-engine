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
      # Without this the task could satisfy its own test by purging everything.
      file = GameFileUpload.new(@game, fixture_upload("photo.jpg"), create_user).call

      Rake::Task["game_files:purge_orphans"].invoke

      expect(file.reload.file).to be_attached
    end
  end
end
