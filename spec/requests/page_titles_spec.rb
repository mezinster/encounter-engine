require "rails_helper"

describe "browser titles", type: :request do
  let(:author) { create_user }
  let(:game)   { g = create_game(:author => author, :name => "Ночной дозор"); set_game_schedule!(g, :starts_at => 1.hour.ago); g }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def title
    Nokogiri::HTML(response.body).at_css("title").text
  end

  it "keeps the bare site name on the home page" do
    get root_path
    expect(title).to eq("Активные городские игры")
  end

  it "titles a guest page with the page and the site" do
    get teams_path
    expect(title).to eq("Команды · Активные городские игры")
  end

  it "titles an operator screen with page, game and site" do
    create_level(:game => game)
    sign_in(author)
    get game_stats_path(game)
    expect(title).to eq("Турнирная таблица — Ночной дозор · Активные городские игры")
  end

  it "titles the game page with the game and the site" do
    sign_in(author)
    get game_path(game)
    expect(title).to eq("Ночной дозор · Активные городские игры")
  end

  it "titles the login page" do
    get login_path
    expect(title).to eq("Вход · Активные городские игры")
  end

  # M1: the play screen and the game page show the name in the player's
  # content language, so the tab must too.
  it "titles the game page with the name in the visitor's content language" do
    draft = create_game(:author => author, :name => "Ночной дозор", :is_draft => true)
    draft.available_locale_list = %w[ru en]
    draft.translations_attributes = { "en" => { "name" => "Night Watch" } }
    draft.save!
    sign_in(author)
    get game_path(draft, :locale => "en")
    expect(title).to eq("Night Watch · Active urban games")
  end

  describe "the remaining player screens" do
    def captain_mid_run
      captain = create_user
      team    = create_team(:captain => captain)
      g       = create_game(:name => "Ночной дозор", :max_skips => 2)
      one     = create_level(:game => g, :position => 1)
      create_level(:game => g, :position => 2)
      set_game_schedule!(g, :starts_at => 1.hour.ago)
      create_game_passing(:level => one, :team => team)
      [ g.reload, captain ]
    end

    it "titles the skip confirmation" do
      g, captain = captain_mid_run
      sign_in(captain)
      get confirm_skip_path(:game_id => g.id)
      expect(title).to eq("Пропуск уровня — Ночной дозор · Активные городские игры")
    end

    it "titles the withdrawn-game explanation" do
      g, captain = captain_mid_run
      g.withdraw!(:category => "technical", :mode => "freeze")
      sign_in(captain)
      get show_current_level_path(:game_id => g.id)
      expect(title).to eq("Игра остановлена — Ночной дозор · Активные городские игры")
    end

    it "titles the access-code redemption form" do
      sign_in(create_user)
      get redeem_access_code_path
      expect(title).to eq("Код доступа · Активные городские игры")
    end

    it "titles the invitation form" do
      captain = create_user
      create_team(:captain => captain)
      sign_in(captain)
      get new_invitation_path
      expect(title).to eq("Приглашение · Активные городские игры")
    end

    it "titles the password reset request" do
      get new_password_reset_path
      expect(title).to eq("Восстановление пароля · Активные городские игры")
    end

    it "titles the user's own profile page" do
      sign_in(create_user)
      get users_path
      expect(title).to eq("Профиль · Активные городские игры")
    end
  end

  describe "the remaining operator screens" do
    it "titles the points adjustment form" do
      create_level(:game => game, :position => 1)
      create_level(:game => game, :position => 2)
      passing = create_game_passing(:level => game.levels.first)
      sign_in(author)
      get new_team_adjustment_path(:game_id => game.id, :team_id => passing.team_id)
      expect(title).to eq("Корректировка очков — Ночной дозор · Активные городские игры")
    end

    it "titles the page that shows freshly created access codes" do
      gated    = create_game(:name => "Ночной дозор", :is_draft => false, :access_mode => "pass_required")
      operator = create_user
      operator.update!(:is_operator => true)
      sign_in(operator)
      post game_access_codes_path(gated), :params => { :count => 2 }
      expect(title).to eq("Новые коды — Ночной дозор · Активные городские игры")
    end

    it "titles the withdrawal form" do
      create_level(:game => game, :position => 1)
      admin = create_user
      admin.update!(:is_superadmin => true)
      sign_in(admin)
      get new_withdrawal_game_path(game)
      expect(title).to eq("Снятие игры — Ночной дозор · Активные городские игры")
    end

    it "titles the test-run invitation" do
      draft = create_game(:author => author, :name => "Ночной дозор", :is_draft => true)
      create_level(:game => draft)
      sign_in(author)
      post start_test_game_path(draft)
      token = draft.reload.current_run.test_token
      delete logout_path
      sign_in(create_user)
      get test_invite_path(:game_id => draft.id, :token => token)
      expect(title).to eq("Приглашение на тестирование — Ночной дозор · Активные городские игры")
    end
  end
end
