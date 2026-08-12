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

      expect(response).not_to have_http_status(:ok)
    end

    it "refuses a signed-out visitor" do
      get game_game_files_path(@game)

      expect(response).not_to have_http_status(:ok)
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
  end
end
