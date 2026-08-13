require "rails_helper"

describe FileAttachable do
  before(:each) do
    @author = create_user
    @game   = create_game(:author => @author)
    @level  = create_level(:game => @game)
    @a = GameFileUpload.new(@game, fixture_upload("photo.jpg"), @author).call
    @b = GameFileUpload.new(@game, fixture_upload("map.pdf"), @author).call
  end

  it "attaches files to the neutral slot" do
    @level.replace_attached_files([ @a.id ], nil)

    expect(@level.file_attachments.reload.map(&:game_file_id)).to eq([ @a.id ])
    expect(@level.file_attachments.first.locale).to be_nil
  end

  it "does NOT disturb the neutral slot when replacing a language slot" do
    # The failure this whole task exists to prevent: an author opens the
    # English tab, picks one file, saves, and every player of every language
    # silently loses the photographs that were on the neutral strip.
    @level.replace_attached_files([ @a.id ], nil)
    @level.replace_attached_files([ @b.id ], "en")

    neutral = @level.file_attachments.reload.where(:locale => nil)
    english = @level.file_attachments.where(:locale => "en")

    expect(neutral.map(&:game_file_id)).to eq([ @a.id ])
    expect(english.map(&:game_file_id)).to eq([ @b.id ])
  end

  it "removes what is no longer picked, within that slot only" do
    @level.replace_attached_files([ @a.id, @b.id ], nil)
    @level.replace_attached_files([ @b.id ], nil)

    expect(@level.file_attachments.reload.map(&:game_file_id)).to eq([ @b.id ])
  end

  it "REFUSES a file from another game, without raising" do
    # The form posts ids. An author can edit them, and FileAttachment's own
    # validator fails closed -- but create! would raise, turning a hostile
    # id into a 500. Filter to the owning game's library first so the row is
    # never attempted.
    other = GameFileUpload.new(create_game(:author => create_user),
                               fixture_upload("photo.jpg"), @author).call

    expect { @level.replace_attached_files([ other.id ], nil) }.not_to raise_error
    expect(@level.file_attachments.reload).to be_empty
  end

  it "works the same on a Hint" do
    hint = create_hint(:level => @level)
    hint.replace_attached_files([ @a.id ], nil)

    expect(hint.file_attachments.reload.map(&:game_file_id)).to eq([ @a.id ])
  end

  it "returns neutral plus the player's language, in position order" do
    @level.replace_attached_files([ @a.id ], nil)
    @level.replace_attached_files([ @b.id ], "en")

    expect(@level.attached_files_for("en").map(&:id)).to match_array([ @a.id, @b.id ])
    expect(@level.attached_files_for("ru").map(&:id)).to eq([ @a.id ])
  end
end
