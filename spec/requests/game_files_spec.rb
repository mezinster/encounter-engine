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
  end
end
