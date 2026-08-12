require "rails_helper"

describe GameFileUpload do
  before(:each) do
    @game = create_game
    @user = create_user
  end

  def upload(name, claimed_type = "application/octet-stream")
    GameFileUpload.new(@game, fixture_upload(name, claimed_type), @user).call
  end

  # Decode, do not ask. Vips.get_suffixes.include?(".heic") is true whenever
  # the .heic loader module registers -- which happens with libheif1 alone,
  # independent of whether any HEVC decoder is installed. On this very host
  # that predicate returned TRUE while every pixel decode failed with a seek
  # 8 bytes past EOF, because libheif was present with only its AV1 plugins
  # and without libheif-plugin-libde265. HEIC is HEVC, not AV1.
  #
  # Registration is not capability. Ask the question you actually mean.
  def heic_capable?
    Vips::Image.new_from_file(heic_fixture_path).write_to_buffer(".jpg")
    true
  rescue Vips::Error
    false
  end

  def heic_fixture_path
    Rails.root.join("spec/fixtures/files/photo.heic").to_s
  end

  describe "accepting a photograph" do
    it "stores it, attached and persisted" do
      file = upload("photo.jpg")

      expect(file).to be_persisted
      expect(file.file).to be_attached
      expect(file.game).to eq(@game)
      expect(file.uploaded_by).to eq(@user)
    end

    it "records the sniffed content type, not the claimed one" do
      file = upload("photo.jpg", "application/pdf")

      expect(file.content_type).to eq("image/jpeg")
    end

    it "builds both variants eagerly, so reading never allocates disk" do
      file = upload("photo.jpg")

      expect(file.web_variant).to be_present
      expect(file.thumb_variant).to be_present
      expect(file.derived_byte_size).to be > 0
    end

    it "sets byte_size to the canonical bytes, not the upload" do
      file = upload("photo.jpg")

      expect(file.byte_size).to eq(file.file.byte_size)
    end
  end

  describe "rejecting" do
    it "a file whose bytes are HTML however it is named" do
      file = upload("not-really.jpg", "image/jpeg")

      expect(file).not_to be_persisted
      expect(file.errors[:file]).not_to be_empty
    end

    it "a type the operator removed from allowed_extensions" do
      Setting.put("allowed_extensions", "png")

      file = upload("photo.jpg")

      expect(file).not_to be_persisted
    end

    # PERMITTED cannot currently reject anything, and that is worth being
    # precise about rather than papering over: MIME_TO_EXTENSION only ever
    # yields jpg/png/gif/heic/pdf, every one of which is already in PERMITTED,
    # so the `& PERMITTED` intersection is unreachable by construction. An
    # end-to-end test is therefore impossible -- an SVG never maps to an
    # extension at all, so it is rejected as unsupported_type and never reaches
    # the intersection. A test asserting otherwise would pass for the wrong
    # reason.
    #
    # PERMITTED still earns its place as a ceiling against a FUTURE edit adding
    # an unsafe mapping. So pin exactly that: the invariant, not the constant.
    it "never maps a MIME type to an extension outside PERMITTED" do
      mapped = GameFileUpload::MIME_TO_EXTENSION.values.uniq

      expect(mapped - GameFile::PERMITTED).to be_empty
    end

    it "a file larger than file_max_megabytes" do
      Setting.put("file_max_megabytes", 0)

      file = upload("photo.jpg")

      expect(file).not_to be_persisted
      expect(file.errors[:file]).not_to be_empty
    end
  end

  describe "canonicalisation" do
    it "strips EXIF, including the GPS that would give a location puzzle away" do
      file = upload("geotagged.jpg")

      file.file.open do |io|
        stored = Vips::Image.new_from_file(io.path)
        expect(stored.get_fields.grep(/GPS/)).to be_empty
      end
    end

    it "converts HEIC to JPEG and says so in the stored name" do
      unless heic_capable?
        # In CI this MUST fail. The shipped image is built with libheif and the
        # app-image job already proves it prints "libvips ok, HEIC ok", so
        # missing capability there means the Dockerfile regressed. Locally it is
        # a machine limitation, not a defect.
        raise "libvips has no HEIC support and this is CI" if ENV["CI"].present?

        skip "libvips here lacks HEIC support; CI covers this conversion"
      end

      file = upload("photo.heic")

      expect(file.content_type).to eq("image/jpeg")
      expect(file.filename).to end_with(".jpg")
    end

    it "leaves a PDF's bytes untouched and gives it no variants" do
      file = upload("map.pdf")

      expect(file.content_type).to eq("application/pdf")
      expect(file.web_variant).to be_nil
      expect(file.thumb_variant).to be_nil
      expect(file.derived_byte_size).to eq(0)
    end

    it "gives a GIF a thumb but leaves web as the original" do
      file = upload("animation.gif")

      expect(file.thumb_variant).to be_present
      expect(file.web_variant).to be_nil
    end
  end

  describe "a file whose pixels fail to decode only after the row is committed" do
    # canonicalise never runs a GIF through Vips -- it passes the raw io
    # straight through (see canonicalise). The first time libvips touches a
    # GIF's pixel data is thumb_variant's `.processed` call inside
    # measure_derived!, which runs AFTER @game.with_lock's transaction has
    # already committed the GameFile row. A GIF that sniffs correctly but
    # fails to decode therefore fails only once a persisted, quota-consuming
    # row already exists.
    it "sniffs as image/gif despite having no valid frame data" do
      mime = File.open(Rails.root.join("spec/fixtures/files/corrupt.gif"), "rb") do |io|
        Marcel::MimeType.for(io)
      end

      expect(mime).to eq("image/gif")
    end

    it "rejects the upload and leaves no row or blob behind" do
      games_before = GameFile.count
      blobs_before = ActiveStorage::Blob.count

      file = upload("corrupt.gif")

      expect(file).not_to be_persisted
      expect(file.errors[:file]).not_to be_empty
      expect(GameFile.count).to eq(games_before)
      expect(ActiveStorage::Blob.count).to eq(blobs_before)
    end

    # The counterpart: a GIF that actually decodes must still succeed, so
    # "reject every GIF" cannot satisfy the example above.
    it "still accepts a GIF that decodes cleanly" do
      file = upload("animation.gif")

      expect(file).to be_persisted
      expect(file.thumb_variant).to be_present
    end
  end

  describe "filename collisions" do
    it "suffixes rather than overwriting, because a game may be running" do
      first  = upload("photo.jpg")
      second = upload("photo.jpg")

      expect(second).to be_persisted
      expect(second.filename).not_to eq(first.filename)
      expect(second.filename).to eq("photo-2.jpg")
    end

    it "retries once when the unique index fires under a race" do
      # The model validation is TOCTOU-racy against its own unique index.
      # Simulate the loser of that race: validation passes, the insert does not.
      # Stub save! (what the code calls), and use a plain local flag so the
      # first call raises and the retry reaches the real implementation.
      raised = false
      allow_any_instance_of(GameFile).to receive(:save!).and_wrap_original do |original, *args|
        unless raised
          raised = true
          raise ActiveRecord::RecordNotUnique, "simulated"
        end

        original.call(*args)
      end

      file = upload("photo.jpg")

      expect(file).to be_persisted
    end
  end

  it "sets all four denormalised fields in one place" do
    file = upload("photo.jpg")

    expect(file.byte_size).to be > 0
    expect(file.content_type).to be_present
    expect(file.checksum).to be_present
    expect(file.derived_byte_size).to be > 0
  end

  describe "disk protection" do
    it "refuses when the game is over its quota" do
      Setting.put("game_quota_megabytes", 0)

      file = upload("photo.jpg")

      expect(file).not_to be_persisted
      expect(file.errors[:file].join).to match(/\d/)   # the message carries numbers
    end

    it "refuses when the instance cap is reached" do
      Setting.put("instance_cap_megabytes", 0)

      expect(upload("photo.jpg")).not_to be_persisted
    end

    it "refuses when free space is below the floor" do
      allow(DiskSpace).to receive(:available_megabytes).and_return(10)
      Setting.put("free_space_floor_megabytes", 3072)

      file = upload("photo.jpg")

      expect(file).not_to be_persisted
    end

    it "allows when free space is above the floor" do
      allow(DiskSpace).to receive(:available_megabytes).and_return(9999)

      expect(upload("photo.jpg")).to be_persisted
    end

    it "counts variants against the quota, not just the canonical bytes" do
      first = upload("photo.jpg")

      expect(GameFile.storage_used_by(@game)).to eq(first.byte_size + first.derived_byte_size)
    end
  end
end
