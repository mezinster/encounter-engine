require "rails_helper"

describe "the game file Explorer", :type => :request do
  def login_as(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  before(:each) do
    @author = create_user
    @game = create_game(:author => @author)
  end

  describe "authorization" do
    it "shows the Explorer to the game's author" do
      login_as(@author)

      get game_game_files_path(@game)

      expect(response).to have_http_status(:ok)
    end

    it "shows it to a superadmin for someone else's game" do
      admin = create_user
      admin.update!(:is_superadmin => true)
      login_as(admin)

      get game_game_files_path(@game)

      expect(response).to have_http_status(:ok)
    end

    it "refuses another author" do
      login_as(create_user)

      get game_game_files_path(@game)

      expect(response).to have_http_status(:unauthorized)
    end

    it "refuses a signed-out visitor" do
      get game_game_files_path(@game)

      expect(response).to have_http_status(:unauthorized)
    end

    it "still lists files for an author whose game is locked for editing" do
      # ensure_editing_not_locked covers content, settings and lifecycle, but
      # read-only views stay off it: an author under investigation may still
      # look at their own game.
      @game.update_column(:editing_locked_at, Time.now)
      login_as(@author)

      get game_game_files_path(@game)

      expect(response).to have_http_status(:ok)
    end
  end

  describe "the listing" do
    it "shows each file's name and where it is used" do
      level = create_level(:game => @game)
      file = create_game_file(:game => @game, :filename => "дом.jpg")
      FileAttachment.create!(:game_file => file, :attachable => level)
      login_as(@author)

      get game_game_files_path(@game)

      expect(response.body).to include("дом.jpg")
      expect(response.body).to include(level.name)
    end

    it "says plainly when a file is attached to nothing" do
      create_game_file(:game => @game, :filename => "двор.jpg")
      login_as(@author)

      get game_game_files_path(@game)

      expect(response.body).to include(I18n.t("game_files.index.unused"))
    end

    it "shows quota usage" do
      create_game_file(:game => @game, :byte_size => 5 * 1024 * 1024, :derived_byte_size => 0)
      login_as(@author)

      get game_game_files_path(@game)

      # The whole rendered sentence, built from the key the view renders, with
      # the interpolations filled in -- so the number AND its context are
      # pinned. This example previously asserted `include("5")`, which cannot
      # fail: the file table's own number_to_human_size cell reads "5 MB" on
      # the same page. Proved by hard-wiring @used_megabytes = 0 in the
      # controller and watching it stay green.
      expect(response.body).to include(
        I18n.t("game_files.index.quota",
               :used => 5, :quota => Setting.integer("game_quota_megabytes"))
      )
    end

    it "rounds the used figure up, so it never claims room that is not there" do
      # 99.9 MB truncates to «Занято 99 МБ из 100 МБ» -- a page telling the
      # author there is a megabyte free while the quota check refuses the very
      # next upload. Overstating what is used is the safe direction.
      quota = Setting.integer("game_quota_megabytes")
      create_game_file(:game => @game,
                       :byte_size => ((quota - 0.1) * 1024 * 1024).to_i,
                       :derived_byte_size => 0)
      login_as(@author)

      get game_game_files_path(@game)

      expect(response.body).to include(
        I18n.t("game_files.index.quota", :used => quota, :quota => quota)
      )
    end

    # Zero is a supported value, not a hypothesis: the validation allows it,
    # the key is on the admin settings page, and Setting's own comment calls it
    # the documented "off" switch an operator reaches for during an incident.
    # The quota bar's inline percentage was NaN.round with no files and
    # Infinity.round with any, and both raise FloatDomainError -- taking down
    # the page every author is redirected to after every upload and delete,
    # while the upload path itself degraded correctly.
    describe "with the quota switched off entirely" do
      before(:each) { Setting.put("game_quota_megabytes", 0) }

      it "renders, with the bar full, when the game has no files" do
        login_as(@author)

        get game_game_files_path(@game)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("width: 100%")
      end

      it "renders, with the bar full, when the game already has files" do
        create_game_file(:game => @game, :byte_size => 1024, :derived_byte_size => 0)
        login_as(@author)

        get game_game_files_path(@game)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("width: 100%")
      end
    end

    it "does not list another game's files" do
      create_game_file(:game => create_game, :filename => "чужой.jpg")
      login_as(@author)

      get game_game_files_path(@game)

      expect(response.body).not_to include("чужой.jpg")
    end

    it "does not ask the database about each file separately" do
      # The page reads every file's attachments twice: once in the controller
      # for @typed_confirmation_ids and once per row in _file_table for the
      # "where it is used" column. Unpreloaded that was 15 queries for 3 files.
      # A slope, not a magic number -- the shape dashboard_queries_spec.rb uses.
      a_file_used_by_a_level = lambda do
        file = create_game_file(:game => @game, :filename => "файл#{rand(10**9)}.jpg")
        FileAttachment.create!(:game_file => file, :attachable => create_level(:game => @game))
      end

      login_as(@author)

      a_file_used_by_a_level.call
      one = count_queries { get game_game_files_path(@game) }

      2.times { a_file_used_by_a_level.call }
      three = count_queries { get game_game_files_path(@game) }

      expect(three).to eq(one),
        "the Explorer issued #{one} queries for one file and #{three} for three -- " \
        "GameFilesController#index or _file_table is reading per row"
    end

    it "shows the level name for a file attached to a hint" do
      level = create_level(:game => @game)
      hint = Hint.create!(:level => level, :text => "подсказка", :delay => 60)
      file = create_game_file(:game => @game, :filename => "подсказка.jpg")
      FileAttachment.create!(:game_file => file, :attachable => hint)
      login_as(@author)

      get game_game_files_path(@game)

      expect(response.body).to include(level.name)
    end
  end

  describe "uploading" do
    def upload(names)
      post game_game_files_path(@game),
           :params => { :files => Array(names).map { |n| fixture_upload(n) } }
    end

    it "stores an accepted file" do
      login_as(@author)

      expect { upload("photo.jpg") }.to change { GameFile.count }.by(1)
      expect(response).to redirect_to(game_game_files_path(@game))
    end

    it "says so when the whole batch went through" do
      # A clean upload used to redirect in silence, which reads as "nothing
      # happened": the new rows are further down a page the author has to scan.
      login_as(@author)

      upload([ "photo.jpg", "small.png" ])

      expect(flash[:notice]).to eq(I18n.t("game_files.upload.uploaded", :count => 2))
      expect(flash[:alert]).to be_blank
    end

    it "stays silent about success when part of the batch was rejected" do
      # The rejection is the message that matters; a cheerful notice beside it
      # would bury it.
      login_as(@author)

      upload([ "photo.jpg", "not-really.jpg" ])

      expect(flash[:notice]).to be_blank
      expect(flash[:alert]).to be_present
    end

    it "processes a batch per file, keeping the ones that fit" do
      # Per-file, not atomic: an author who picked one bad photo must not have to
      # re-select all the others.
      login_as(@author)

      expect { upload([ "photo.jpg", "not-really.jpg" ]) }.to change { GameFile.count }.by(1)
    end

    it "names the rejected file so the author knows which one failed" do
      login_as(@author)

      upload("not-really.jpg")

      expect(flash[:alert]).to include("not-really.jpg")
    end

    it "refuses a batch larger than max_files_per_upload without storing any of it" do
      Setting.put("max_files_per_upload", 1)
      login_as(@author)

      expect { upload([ "photo.jpg", "small.png" ]) }.not_to change { GameFile.count }
      expect(flash[:alert]).to eq(GameFileUpload.batch_limit_message)
    end

    it "refuses an upload to a game locked for editing" do
      @game.update_column(:editing_locked_at, Time.now)
      login_as(@author)

      expect { upload("photo.jpg") }.not_to change { GameFile.count }
      expect(response).to have_http_status(:unauthorized)
    end

    it "refuses another author" do
      login_as(create_user)

      expect { upload("photo.jpg") }.not_to change { GameFile.count }
      expect(response).to have_http_status(:unauthorized)
    end

    # files[] is attacker-controlled independently of the HTML form: a
    # hand-built multipart request can put a plain string, not an uploaded
    # file, at any slot. These two guard against a 500 in that case rather
    # than the graceful per-file rejection the rest of this batch gives every
    # other kind of bad input.
    it "rejects a malformed files[] entry without raising, and stores nothing" do
      login_as(@author)

      expect {
        post game_game_files_path(@game), :params => { :files => [ "not-a-file-upload" ] }
      }.not_to change { GameFile.count }

      expect(response).to redirect_to(game_game_files_path(@game))
    end

    it "keeps an earlier valid file when a later entry is malformed, and names the failure" do
      # Order matters: the valid file's GameFileUpload#call commits its own
      # transaction before the malformed entry is even looked at, so a naive
      # fix could still let that commit ride behind an unhandled 500 the
      # author never sees resolved.
      login_as(@author)

      expect {
        post game_game_files_path(@game),
             :params => { :files => [ fixture_upload("photo.jpg"), "not-a-file-upload" ] }
      }.to change { GameFile.count }.by(1)

      expect(response).to redirect_to(game_game_files_path(@game))
      expect(flash[:alert]).to include("not-a-file-upload")
    end
  end

  describe "deleting" do
    it "removes an unused file and its blob" do
      file = create_game_file(:game => @game)
      login_as(@author)

      expect { delete game_game_file_path(@game, file) }.to change { GameFile.count }.by(-1)
    end

    it "removes an attached file when the game is not running" do
      level = create_level(:game => @game)
      file = create_game_file(:game => @game)
      FileAttachment.create!(:game_file => file, :attachable => level)
      login_as(@author)

      expect { delete game_game_file_path(@game, file) }.to change { GameFile.count }.by(-1)
    end

    it "refuses an attached file in a RUNNING game without the typed filename" do
      level = create_level(:game => @game)
      file = create_game_file(:game => @game, :filename => "дом.jpg")
      FileAttachment.create!(:game_file => file, :attachable => level)
      allow_any_instance_of(Game).to receive(:status).and_return(:running)
      login_as(@author)

      expect { delete game_game_file_path(@game, file) }.not_to change { GameFile.count }
    end

    it "accepts the typed filename in a running game" do
      level = create_level(:game => @game)
      file = create_game_file(:game => @game, :filename => "дом.jpg")
      FileAttachment.create!(:game_file => file, :attachable => level)
      allow_any_instance_of(Game).to receive(:status).and_return(:running)
      login_as(@author)

      expect {
        delete game_game_file_path(@game, file), :params => { :confirm_filename => "дом.jpg" }
      }.to change { GameFile.count }.by(-1)
    end

    it "accepts the typed filename with stray whitespace around it" do
      # A trailing space off a mobile keyboard is a realistic way to type the
      # name correctly and be refused, and tolerating it costs nothing: an
      # author who cannot produce the name still cannot delete. Exact
      # otherwise -- the example below keeps the comparison honest.
      level = create_level(:game => @game)
      file = create_game_file(:game => @game, :filename => "дом.jpg")
      FileAttachment.create!(:game_file => file, :attachable => level)
      allow_any_instance_of(Game).to receive(:status).and_return(:running)
      login_as(@author)

      expect {
        delete game_game_file_path(@game, file), :params => { :confirm_filename => " дом.jpg " }
      }.to change { GameFile.count }.by(-1)
    end

    it "refuses a delete in a game locked for editing" do
      # The lock exists so an author under investigation cannot erase evidence,
      # and photographs ARE evidence -- so the delete half of
      # ensure_editing_not_locked matters at least as much as the upload half.
      # Proved by mutation: dropping :destroy from the filter's :only list left
      # every other example in this file green.
      file = create_game_file(:game => @game)
      @game.update_column(:editing_locked_at, Time.now)
      login_as(@author)

      expect { delete game_game_file_path(@game, file) }.not_to change { GameFile.count }
      expect(response).to have_http_status(:unauthorized)
    end

    it "does not accept a wrong typed filename" do
      # Otherwise the confirmation is theatre: any non-empty value would pass.
      level = create_level(:game => @game)
      file = create_game_file(:game => @game, :filename => "дом.jpg")
      FileAttachment.create!(:game_file => file, :attachable => level)
      allow_any_instance_of(Game).to receive(:status).and_return(:running)
      login_as(@author)

      expect {
        delete game_game_file_path(@game, file), :params => { :confirm_filename => "что-нибудь" }
      }.not_to change { GameFile.count }
    end

    it "refuses another author" do
      file = create_game_file(:game => @game)
      login_as(create_user)

      expect { delete game_game_file_path(@game, file) }.not_to change { GameFile.count }
      expect(response).to have_http_status(:unauthorized)
    end

    it "removes an attached file without a typed filename when the game has finished" do
      # started? is ALSO true here (starts_at is in the past), which is
      # exactly why the controller must gate on status == :running rather than
      # started? -- a finished game where deleting a photo harms nobody must
      # not demand the typed confirmation.
      level = create_level(:game => @game)
      file = create_game_file(:game => @game)
      FileAttachment.create!(:game_file => file, :attachable => level)
      set_game_schedule!(@game, :starts_at => 1.day.ago, :author_finished_at => Time.now)
      expect(@game.status).to eq(:finished)
      login_as(@author)

      expect { delete game_game_file_path(@game, file) }.to change { GameFile.count }.by(-1)
    end

    it "404s on a file that belongs to a different game and does not destroy it" do
      # GameFile.of_game(@game).find(params[:id]) is scoped by construction,
      # but nothing else in this file exercised the scope -- without it, a
      # request pairing this game's id with another game's file id would
      # delete a file no author of @game should be able to touch.
      other_file = create_game_file(:game => create_game)
      login_as(@author)

      expect {
        expect { delete game_game_file_path(@game, other_file) }
          .to raise_error(ActiveRecord::RecordNotFound)
      }.not_to change { GameFile.count }
    end
  end
end
