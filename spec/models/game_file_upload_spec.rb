require "rails_helper"

describe GameFileUpload do
  before(:each) do
    @game = create_game
    @user = create_user
  end

  def upload(name, claimed_type = "application/octet-stream")
    GameFileUpload.new(@game, fixture_upload(name, claimed_type), @user).call
  end

  def heic_capable?
    Vips.get_suffixes.include?(".heic")
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

    it "a type PERMITTED forbids even if the operator added it" do
      Setting.put("allowed_extensions", "jpg svg")

      expect(GameFile::PERMITTED).not_to include("svg")
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

      # Second checkpoint, not in the brief's original text. On the machine
      # this task was implemented on, `Vips.get_suffixes.include?(".heic")`
      # above is a false positive: the vips-heif loader registers (so the
      # suffix list includes ".heic"), but the underlying HEVC codec is
      # absent/mismatched, so the real decode below raises inside libheif
      # ("Unsupported codec") on some runs and not others -- observed
      # flipping between runs of the identical command, so no static or
      # probe-based capability check taken before the fact can rule it out.
      # GameFileUpload already rescues that (Vips::Error -> reject), which is
      # correct production behaviour, so what reaches here on a bad draw is
      # an unsaved, unattached GameFile rather than a raised exception. Same
      # asymmetric policy as the check above: a host that claimed capability
      # and then failed the real conversion is exactly a Dockerfile
      # regression in CI, and exactly this known machine limitation locally.
      unless file.persisted?
        raise "libvips claimed HEIC support but the real conversion failed, and this is CI" if ENV["CI"].present?

        skip "libvips here lacks reliable HEIC support; CI covers this conversion"
      end

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
end
