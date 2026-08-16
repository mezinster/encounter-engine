require "rails_helper"

describe "translation screens", type: :request do
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:author)     { create_user }

  # :is_draft is load-bearing in this fixture, not decoration. create_game
  # leaves a game PUBLISHED, and declared_locales_are_translated_before_publication
  # refuses to let a published game declare a locale it has not translated --
  # so a `ru en` game blows up on save! before any example body runs. A draft
  # is exempt (`return if self.draft?`), which is what these specs want anyway.
  let(:game)       { create_game(:author => author, :is_draft => true,
                                 :primary_locale => "ru",
                                 :available_locale_list => %w[ru en]) }
  let!(:level)     { create_level(:game => game, :name => "Первый", :text => "Найдите табличку") }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  before { allow(Translation::Client).to receive(:configured?).and_return(true) }

  it "offers a Translate button per locale to a superadmin on the edit screen" do
    sign_in(superadmin)
    get edit_game_path(game)

    expect(response.body).to include(game_translation_runs_path(game))
    expect(response.body).to include(I18n.t("translations.edit.translate"))
  end

  it "offers nothing to the author, who cannot use the feature" do
    sign_in(author)
    get edit_game_path(game)

    expect(response.body).not_to include(I18n.t("translations.edit.translate"))
  end

  it "offers nothing when no API key is configured" do
    allow(Translation::Client).to receive(:configured?).and_return(false)
    sign_in(superadmin)
    get edit_game_path(game)

    expect(response.body).not_to include(I18n.t("translations.edit.translate"))
  end

  # Polling with no JavaScript at all. The refresh must disappear the moment
  # the run is terminal, or a finished page reloads forever.
  it "auto-refreshes only while the run is still going" do
    run = TranslationRun.create!(:game => game, :actor => superadmin,
                                 :model => "claude-opus-5", :state => TranslationRun::RUNNING,
                                 :fields_total => 4, :fields_done => 1)
    sign_in(superadmin)

    get game_translation_run_path(game, run)
    expect(response.body).to include("http-equiv=\"refresh\"")
    expect(response.body).to include(I18n.t("translations.show.progress", :done => 1, :total => 4))

    run.update!(:state => TranslationRun::SUCCEEDED)
    get game_translation_run_path(game, run)
    expect(response.body).not_to include("http-equiv=\"refresh\"")
  end

  it "shows source beside proposal and names each flag on the review screen" do
    run = TranslationRun.create!(:game => game, :actor => superadmin,
                                 :model => "claude-opus-5", :state => TranslationRun::SUCCEEDED)
    TranslationProposal.create!(:translation_run => run, :translatable => level,
                                :field => "text", :locale => "en",
                                :source_text => "Найдите табличку",
                                :proposed_text => "Найдите табличку",
                                :flags => "identical", :state => "pending")
    sign_in(superadmin)

    get game_translation_run_proposals_path(game, run)

    expect(response.body).to include("Найдите табличку")
    expect(response.body).to include(I18n.t("translations.flags.identical"))
  end

  # Beyond the brief: Task 7's review noted that a background thread which
  # dies before its own rescue block runs leaves a run stuck PENDING -- and
  # PENDING counts as active (TranslationRun::ACTIVE_STATES), so the game is
  # then blocked from starting any new run. The run page is the only place a
  # human can act on that, so Cancel must be offered on a pending run too,
  # not only a running one. Task 10 adds an automatic sweep; this is the
  # manual escape hatch until then.
  it "offers Cancel on a pending run, not only a running one" do
    run = TranslationRun.create!(:game => game, :actor => superadmin,
                                 :model => "claude-opus-5", :state => TranslationRun::PENDING,
                                 :fields_total => 4, :fields_done => 0)
    sign_in(superadmin)

    get game_translation_run_path(game, run)

    expect(response.body).to include(cancel_game_translation_run_path(game, run))
    expect(response.body).to include(I18n.t("translations.show.cancel"))
  end
end
