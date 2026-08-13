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

  it "folds the picker's blank locale param onto the neutral slot" do
    # The picker posts locale="" for the primary tab (see the method
    # comment). Without `.presence`-style folding this would create a THIRD
    # slot with locale == "" -- one `for_locale`'s `IS NULL OR = ?` can never
    # match, so the author's neutral picks would vanish from every player's
    # strip while the editor still showed them saved.
    @level.replace_attached_files([ @a.id ], "")

    expect(@level.file_attachments.reload.pluck(:locale)).to eq([ nil ])
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

  it "resets the association so a same-request read is not stale" do
    # Task 2's picker calls replace_attached_files and then re-renders the
    # checked state from level.file_attachments in the SAME request, with no
    # reload in between. Without file_attachments.reset, a de-selected file
    # would still render as ticked.
    @level.replace_attached_files([ @a.id, @b.id ], nil)
    @level.file_attachments.load # warm the association, like a controller that read it earlier in the request

    @level.replace_attached_files([ @b.id ], nil)

    expect(@level.file_attachments.map(&:game_file_id)).to eq([ @b.id ])
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

  # attached_files_for has two branches (see the method's own comment):
  # read the already-loaded file_attachments array in Ruby when the caller
  # preloaded it (the play screen, game_passings_controller.rb -- the branch
  # PRODUCTION actually takes for this method), or fall back to the original
  # .for_locale(...).includes(:game_file) query when nothing was preloaded
  # (every OTHER caller: the picker, and @level itself here, whose
  # file_attachments association is never eager-loaded by anything above).
  # Both examples below are parameterised over the two, so neither branch is
  # asserted only by "does not raise": swapping the loaded branch's
  # `file_attachments.select { ... }` for a bare `file_attachments.to_a` (no
  # locale filter at all) passes the fallback half and fails the preloaded
  # half.
  def preloaded(level)
    Level.includes(:file_attachments => :game_file).find(level.id)
  end

  it "returns neutral plus the player's language, in position order" do
    @level.replace_attached_files([ @a.id ], nil)
    @level.replace_attached_files([ @b.id ], "en")

    [ @level, preloaded(@level) ].each do |level|
      expect(level.attached_files_for("en").map(&:id)).to eq([ @a.id, @b.id ])
      expect(level.attached_files_for("ru").map(&:id)).to eq([ @a.id ])
    end
  end

  it "puts the whole neutral strip before the whole language strip, deterministically" do
    # position is scoped PER SLOT, so both slots start at 1 -- a plain
    # ORDER BY position interleaves them and lets ties fall to whatever the
    # engine returns. Two neutral files [a(1), extra(2)] and one English-only
    # file [b(1)] must always read as [a, extra, b], on SQLite (this suite)
    # and on Postgres (production) alike -- never with b sandwiched between
    # the two neutral files because it happened to tie a's position.
    extra = create_game_file(:game => @game)

    @level.replace_attached_files([ @a.id ], nil)
    @level.replace_attached_files([ @a.id, extra.id ], nil) # only extra is new -> deterministically position 2
    @level.replace_attached_files([ @b.id ], "en")

    [ @level, preloaded(@level) ].each do |level|
      expect(level.attached_files_for("en").map(&:id)).to eq([ @a.id, extra.id, @b.id ])
    end
  end

  describe "locale handling on the way in, as defensive as file-id handling" do
    it "REFUSES a locale the app does not serve, without touching any slot, without raising" do
      @level.replace_attached_files([ @a.id ], nil)

      expect { @level.replace_attached_files([ @b.id ], "de") }.not_to raise_error

      expect(@level.file_attachments.reload.map(&:locale)).to eq([ nil ])
      expect(@level.file_attachments.map(&:game_file_id)).to eq([ @a.id ])
    end

    it "strips padding before matching it to a served locale's slot" do
      @level.replace_attached_files([ @a.id ], "en")

      expect { @level.replace_attached_files([ @b.id ], " en ") }.not_to raise_error

      english = @level.file_attachments.reload.where(:locale => "en")
      expect(english.map(&:game_file_id)).to eq([ @b.id ])
    end

    it "folds a whitespace-only locale onto the neutral slot" do
      @level.replace_attached_files([ @a.id ], "  ")

      expect(@level.file_attachments.reload.map(&:locale)).to eq([ nil ])
    end
  end

  it "REFUSES rather than wipes when the attachable's game cannot be resolved" do
    # owning_game returns nil for a hint with no level. The naive fix -- let
    # `wanted` degrade to [] -- still runs destroy_all against whatever the
    # slot already holds, deleting it. Refusing outright leaves it alone.
    hint = create_hint(:level => @level)
    hint.replace_attached_files([ @a.id ], nil)
    hint.level = nil

    expect { hint.replace_attached_files([], nil) }.not_to raise_error
    expect(hint.file_attachments.reload.map(&:game_file_id)).to eq([ @a.id ])
  end
end
