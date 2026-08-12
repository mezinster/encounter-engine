require "rails_helper"

describe FileAttachment do
  before(:each) do
    @game  = create_game
    @level = create_level(:game => @game)
    @file  = create_game_file(:game => @game)
  end

  it "attaches a file to a level" do
    attachment = FileAttachment.create!(:game_file => @file, :attachable => @level)

    expect(@level.reload.file_attachments).to eq([attachment])
    expect(@level.game_files).to eq([@file])
  end

  it "attaches a file to a hint" do
    hint = Hint.create!(:level => @level, :text => "подсказка", :delay => 60)
    attachment = FileAttachment.create!(:game_file => @file, :attachable => hint)

    expect(hint.reload.file_attachments).to eq([attachment])
    expect(hint.game_files).to eq([@file])
  end

  it "refuses a file from a different game" do
    # Otherwise an author could attach another game's photo, and the serving
    # controller's authorization is scoped by game -- the attachment would
    # exist and the image would 404 for every player.
    foreign = create_game_file(:game => create_game)

    attachment = FileAttachment.new(:game_file => foreign, :attachable => @level)

    expect(attachment).not_to be_valid
    expect(attachment.errors[:game_file]).not_to be_empty
  end

  it "requires a game_file" do
    expect(FileAttachment.new(:attachable => @level)).not_to be_valid
  end

  it "requires something to attach to" do
    expect(FileAttachment.new(:game_file => @file)).not_to be_valid
  end

  describe "when the attachable's game cannot be resolved" do
    # Fail closed: "I cannot tell which game this belongs to" is not "fine".
    # A validator whose entire job is keeping one game's files out of
    # another game's levels must refuse rather than silently no-op.
    it "refuses attaching to a level with no game" do
      gameless_level = Level.new
      foreign = create_game_file(:game => create_game)

      attachment = FileAttachment.new(:game_file => foreign, :attachable => gameless_level)

      expect(attachment).not_to be_valid
      expect(attachment.errors[:attachable]).not_to be_empty
    end

    it "refuses attaching to a hint whose level has no game" do
      gameless_level = Level.new
      hint = Hint.new(:level => gameless_level)
      foreign = create_game_file(:game => create_game)

      attachment = FileAttachment.new(:game_file => foreign, :attachable => hint)

      expect(attachment).not_to be_valid
      expect(attachment.errors[:attachable]).not_to be_empty
    end

    it "refuses attaching to a hint with no level" do
      hint = Hint.new(:level => nil)
      foreign = create_game_file(:game => create_game)

      attachment = FileAttachment.new(:game_file => foreign, :attachable => hint)

      expect(attachment).not_to be_valid
      expect(attachment.errors[:attachable]).not_to be_empty
    end
  end

  describe "locale scoping" do
    it "defaults to NULL, meaning every language" do
      attachment = FileAttachment.create!(:game_file => @file, :attachable => @level)

      expect(attachment.locale).to be_nil
    end

    it "includes NULL rows for every locale" do
      neutral = FileAttachment.create!(:game_file => @file, :attachable => @level)

      expect(FileAttachment.for_locale("en")).to include(neutral)
      expect(FileAttachment.for_locale("ru")).to include(neutral)
    end

    it "includes a locale-specific row only for its own locale" do
      english = FileAttachment.create!(:game_file => create_game_file(:game => @game),
                                       :attachable => @level, :locale => "en")

      expect(FileAttachment.for_locale("en")).to include(english)
      expect(FileAttachment.for_locale("ru")).not_to include(english)
    end

    it "refuses a locale the application does not serve" do
      attachment = FileAttachment.new(:game_file => @file, :attachable => @level,
                                      :locale => "zz")

      expect(attachment).not_to be_valid
    end

    it "does not raise when joined against content_translations, which also has a locale column" do
      # The play screen resolves content translations and renders the
      # attachment strip in the same query path. Without table-qualifying
      # for_locale's SQL, this raises
      # SQLite3::SQLException: ambiguous column name: locale -- a bug invisible
      # to any spec that doesn't join both tables together.
      FileAttachment.create!(:game_file => @file, :attachable => @level)

      expect {
        Level.joins(:file_attachments).joins(:content_translations)
             .merge(FileAttachment.for_locale("ru")).to_a
      }.not_to raise_error
    end
  end

  describe "ordering" do
    it "numbers attachments from 1 in the order they are added" do
      first  = FileAttachment.create!(:game_file => @file, :attachable => @level)
      second = FileAttachment.create!(:game_file => create_game_file(:game => @game),
                                      :attachable => @level)

      expect([ first.reload.position, second.reload.position ]).to eq([ 1, 2 ])
    end

    it "numbers each level's list independently" do
      other_level = create_level(:game => @game)
      FileAttachment.create!(:game_file => @file, :attachable => @level)
      elsewhere = FileAttachment.create!(:game_file => create_game_file(:game => @game),
                                         :attachable => other_level)

      expect(elsewhere.reload.position).to eq(1)
    end

    it "numbers a locale-specific list independently from the NULL-locale list" do
      null_first = FileAttachment.create!(:game_file => @file, :attachable => @level)
      english = FileAttachment.create!(:game_file => create_game_file(:game => @game),
                                       :attachable => @level, :locale => "en")
      null_second = FileAttachment.create!(:game_file => create_game_file(:game => @game),
                                           :attachable => @level)

      expect(null_first.reload.position).to eq(1)
      expect(english.reload.position).to eq(1)
      expect(null_second.reload.position).to eq(2)
    end
  end

  it "is destroyed with its level, leaving the library file alone" do
    FileAttachment.create!(:game_file => @file, :attachable => @level)

    expect { @level.destroy }.to change { FileAttachment.count }.by(-1)
    expect(GameFile.exists?(@file.id)).to be(true)
  end

  it "is destroyed with its game_file" do
    FileAttachment.create!(:game_file => @file, :attachable => @level)

    expect { @file.destroy }.to change { FileAttachment.count }.by(-1)
  end
end
