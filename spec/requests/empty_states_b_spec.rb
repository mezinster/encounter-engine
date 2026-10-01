require "rails_helper"

# Designed empty states for the operator and author screens (E1 polish, task 9).
# Three of them live inside [data-live] regions that live_region.js swaps by id,
# so the region must survive being empty. Russian is pinned literally --
# include(I18n.t(...)) would pass on a missing key.
describe "empty states on operator and author screens", type: :request do
  let(:forbidden) do
    [
      "не используется", "photo.jpg", "(принять)", "(отказать)",
      "Добавить новое задание", "Начать тестирование", "Предстоит игра"
    ]
  end
  let(:author) { create_user }
  let(:game)   { g = create_game(:author => author, :is_draft => false); set_game_schedule!(g, :starts_at => 1.hour.ago); g }
  let!(:level) { create_level(:game => game) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def page
    Nokogiri::HTML(response.body)
  end

  def titles
    page.css(".empty-state .empty-state-title").map(&:text)
  end

  def expect_clean_copy
    forbidden.each { |s| expect(response.body).not_to include(s) }
  end

  describe "standings" do
    it "puts a card inside #standings-live instead of the table" do
      sign_in(author)
      get game_stats_path(game)

      live = page.at_css("#standings-live[data-live]")
      expect(live).to be_present
      expect(live.at_css(".empty-state-title").text).to eq("Команды ещё не начали")
      expect(response.body).to include("Команды появятся здесь, как только начнут игру.")
      expect(page.at_css("table#stats")).to be_nil
      expect(page.css(".ops > *").map { |n| n["class"] }).to eq(["table-wrap", "ops-full-log", "opbar"])
      expect_clean_copy
    end

    it "keeps the table and shows no card when a team has started" do
      create_game_passing(:level => level)
      sign_in(author)
      get game_stats_path(game)

      expect(page.at_css("#standings-live[data-live] table#stats")).to be_present
      expect(titles).to be_empty
    end
  end

  describe "results" do
    it "puts a card inside #results-live instead of the table" do
      sign_in(author)
      get "/stats/show_results/#{game.id}"

      live = page.at_css("#results-live[data-live]")
      expect(live).to be_present
      expect(live.at_css(".empty-state-title").text).to eq("Финишировавших пока нет")
      expect(response.body).to include("Команды появятся здесь, когда пройдут последний уровень.")
      expect(page.at_css("table#results")).to be_nil
      expect_clean_copy
    end

    it "keeps the table when a team has finished" do
      create_game_passing(:level => level).update_column(:finished_at, Time.now)
      sign_in(author)
      get "/stats/show_results/#{game.id}"

      expect(page.at_css("#results-live[data-live] table#results")).to be_present
      expect(titles).to be_empty
    end
  end

  describe "live channel" do
    it "puts a card inside #livechannel-live instead of the table" do
      sign_in(author)
      get show_live_channel_path(:game_id => game.id)

      live = page.at_css("#livechannel-live[data-live]")
      expect(live).to be_present
      expect(live.at_css(".empty-state-title").text).to eq("Ответов пока нет")
      expect(response.body).to include("Ответы команд появятся здесь в момент отправки.")
      # The frozen live-channel feature expects the column headings on an empty channel.
      expect(live.at_css("table#livechannel thead th").text).to eq("Время")
      expect(live.css("table#livechannel tbody tr")).to be_empty
      expect_clean_copy
    end

    it "keeps the table when an answer exists" do
      create_log(:game => game, :level => level, :team => create_team, :game_run => game.current_run, :answer => "мост")
      sign_in(author)
      get show_live_channel_path(:game_id => game.id)

      expect(page.at_css("#livechannel-live[data-live] table#livechannel tbody tr")).to be_present
      expect(titles).to be_empty
    end
  end

  describe "level and game logs" do
    let(:team) { create_team }
    before { create_game_passing(:level => level, :team => team) }

    it "shows one dim line instead of an empty list on the level log" do
      sign_in(author)
      get show_level_log_path(:game_id => game.id, :team_id => team.id)

      expect(page.css("p.empty-state-line").map(&:text)).to eq(["Ответов нет"])
      expect(page.css("li").map(&:text).join).not_to match(/\d\d:\d\d:\d\d/)
      expect_clean_copy
    end

    it "shows the list on the level log when answers exist" do
      create_log(:game => game, :level => level, :team => team, :game_run => game.current_run, :answer => "мост")
      sign_in(author)
      get show_level_log_path(:game_id => game.id, :team_id => team.id)

      expect(page.css("ul li").map(&:text).join).to include("мост")
      expect(page.css("p.empty-state-line")).to be_empty
    end

    it "shows one line per level without answers on the game log" do
      level2 = create_level(:game => game)
      create_log(:game => game, :level => level, :team => team, :game_run => game.current_run, :answer => "мост")
      sign_in(author)
      get show_game_log_path(:game_id => game.id, :team_id => team.id)

      expect(page.css("p.empty-state-line").map(&:text)).to eq(["Ответов нет"])
      expect(page.css("li").map(&:text).grep(/\d\d:\d\d:\d\d.*мост/).size).to eq(1)
      expect(level2).to be_present
    end
  end

  describe "game files" do
    it "shows a card instead of the file table when the library is empty" do
      sign_in(author)
      get game_game_files_path(game)

      expect(titles).to eq(["Файлов пока нет"])
      expect(response.body).to include("Загрузите фотографии или PDF формой выше.")
      expect(page.at_css("table.file-table")).to be_nil
      expect_clean_copy
    end

    it "keeps the table when a file exists" do
      create_game_file(:game => game, :filename => "plan.jpg")
      sign_in(author)
      get game_game_files_path(game)

      expect(page.at_css("table.file-table")).to be_present
      expect(titles).to be_empty
    end
  end

  describe "access codes and passes" do
    let(:gated)    { create_game(:is_draft => false, :access_mode => "pass_required") }
    let(:operator) { u = create_user; u.update!(:is_operator => true); u }

    it "shows a card under the codes heading when there are no batches" do
      sign_in(operator)
      get game_access_codes_path(gated)

      expect(titles).to eq(["Кодов пока нет"])
      expect(response.body).to include("Создайте партию кодов формой выше.")
      expect(page.css("table.table--cards")).to be_empty
      expect_clean_copy
    end

    it "keeps the codes table when a batch exists" do
      AccessCode.generate_batch!(:game => gated, :count => 2, :issued_by => operator)
      sign_in(operator)
      get game_access_codes_path(gated)

      expect(page.at_css("table.table--cards")).to be_present
      expect(titles).to be_empty
    end

    it "shows a card instead of the passes table when none were issued" do
      sign_in(operator)
      get game_access_passes_path(gated)

      expect(titles).to eq(["Доступов пока нет"])
      expect(response.body).to include("Выдайте доступ команде формой выше.")
      expect(page.css("table.table--cards")).to be_empty
      expect_clean_copy
    end

    it "keeps the passes table when a pass exists" do
      create_access_pass(:game => gated)
      sign_in(operator)
      get game_access_passes_path(gated)

      expect(page.at_css("table.table--cards")).to be_present
      expect(titles).to be_empty
    end
  end

  describe "translation proposals" do
    let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }
    let(:tgame) { create_game(:author => create_user, :is_draft => true, :primary_locale => "ru", :available_locale_list => %w[ru en]) }
    let(:tlevel) { create_level(:game => tgame, :name => "Первый", :text => "Найдите табличку") }
    let(:run) do
      TranslationRun.create!(:game => tgame, :actor => superadmin, :model => "claude-opus-5",
                             :state => TranslationRun::SUCCEEDED)
    end

    before do
      allow(Translation::Client).to receive(:configured?).and_return(true)
      sign_in(superadmin)
    end

    it "shows a card and no bulk buttons when the run proposed nothing" do
      get game_translation_run_proposals_path(tgame, run)

      expect(titles).to eq(["Предложений нет"])
      expect(response.body).to include("Этот прогон перевода ничего не предложил.")
      expect(page.at_css("table.proposals")).to be_nil
      expect(page.css("form[action*='accept']")).to be_empty
    end

    it "keeps the table and accept-all button when proposals exist" do
      TranslationProposal.create!(:translation_run => run, :translatable => tlevel, :field => "name",
                                  :locale => "en", :source_text => "Первый", :proposed_text => "First",
                                  :state => "pending")
      get game_translation_run_proposals_path(tgame, run)

      expect(page.at_css("table.proposals tbody tr")).to be_present
      expect(page.css("form[action*='accept_all']")).not_to be_empty
      expect(titles).to be_empty
    end
  end
end
