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

      # 5 of 100 MB. The megabyte figure, not the byte count.
      expect(response.body).to include("5")
      expect(response.body).to include(Setting.integer("game_quota_megabytes").to_s)
    end

    it "does not list another game's files" do
      create_game_file(:game => create_game, :filename => "чужой.jpg")
      login_as(@author)

      get game_game_files_path(@game)

      expect(response.body).not_to include("чужой.jpg")
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
    end
  end
end
