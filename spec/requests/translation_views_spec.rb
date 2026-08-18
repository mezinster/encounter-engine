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

  # The flagged rows and their reasons ARE the confirmation step for this
  # button, which is why it sits under the table rather than beside accept_all
  # at the top, and why the count is in the label: pressing it is a decision
  # about a specific number of proposals the reviewer has just read.
  describe "the bulk button for flagged proposals" do
    let(:run) do
      TranslationRun.create!(:game => game, :actor => superadmin,
                             :model => "claude-opus-5", :state => TranslationRun::SUCCEEDED)
    end

    def proposal(field, text, flags: nil)
      TranslationProposal.create!(:translation_run => run, :translatable => level,
                                  :field => field, :locale => "en",
                                  :source_text => level[field].to_s, :proposed_text => text,
                                  :flags => flags, :state => "pending")
    end

    it "offers it with the number of flagged proposals in the label" do
      proposal("text", "Найдите табличку", :flags => "identical")
      proposal("name", "The first")
      sign_in(superadmin)

      get game_translation_run_proposals_path(game, run)

      expect(response.body).to include(accept_flagged_game_translation_run_proposals_path(game, run))
      expect(response.body).to include(I18n.t("translations.review.accept_flagged", :count => 1))
    end

    # The count is the confirmation step, so it has to name exactly what the
    # button will accept. Blank output is flagged but never bulk-accepted.
    it "counts only what the button will actually accept" do
      proposal("text", "Найдите табличку", :flags => "identical")
      proposal("name", "", :flags => "empty")
      sign_in(superadmin)

      get game_translation_run_proposals_path(game, run)

      expect(response.body).to include(I18n.t("translations.review.accept_flagged", :count => 1))
    end

    it "does not offer it when nothing is flagged" do
      proposal("name", "The first")
      sign_in(superadmin)

      get game_translation_run_proposals_path(game, run)

      expect(response.body).not_to include(accept_flagged_game_translation_run_proposals_path(game, run))
    end
  end

  # Beyond the brief: Task 7's review noted that a background thread which
  # dies before its own rescue block runs leaves a run stuck PENDING -- and
  # PENDING counts as active (TranslationRun::ACTIVE_STATES), so the game is
  # then blocked from starting any new run. The run page is the only place a
  # human can act on that, so Cancel must be offered on a pending run too,
  # not only a running one. Task 10 adds an automatic sweep; this is the
  # manual escape hatch until then.
  # Retry is what makes the runner's resumability reachable. Without the
  # button, a run that failed at 90% could only be redone as a NEW run, whose
  # already_proposed? scope is empty -- everything re-translated, everything
  # re-paid for.
  it "offers Retry on a failed run" do
    run = TranslationRun.create!(:game => game, :actor => superadmin,
                                 :model => "claude-opus-5", :state => TranslationRun::FAILED,
                                 :fields_total => 4, :fields_done => 3)
    sign_in(superadmin)

    get game_translation_run_path(game, run)

    expect(response.body).to include(retry_game_translation_run_path(game, run))
    expect(response.body).to include(I18n.t("translations.show.retry"))
  end

  it "offers no Retry on a succeeded or cancelled run" do
    sign_in(superadmin)

    [ TranslationRun::SUCCEEDED, TranslationRun::CANCELLED ].each do |state|
      run = TranslationRun.create!(:game => game, :actor => superadmin,
                                   :model => "claude-opus-5", :state => state)
      get game_translation_run_path(game, run)

      expect(response.body).not_to include(retry_game_translation_run_path(game, run))
      run.destroy!
    end
  end

  # estimated_input_tokens was a dead column until the pre-flight landed.
  it "shows the pre-flight estimate beside the real spend, when there is one" do
    run = TranslationRun.create!(:game => game, :actor => superadmin,
                                 :model => "claude-opus-5", :state => TranslationRun::SUCCEEDED,
                                 :estimated_input_tokens => 12_345)
    sign_in(superadmin)

    get game_translation_run_path(game, run)

    expect(response.body).to include(I18n.t("translations.show.estimate"))
    expect(response.body)
      .to include(ActionController::Base.helpers.number_with_delimiter(12_345))
  end

  # A zero is not an estimate of zero, it is the absence of one -- runs made
  # before the pre-flight existed all carry it.
  it "shows no estimate row when the run was never priced" do
    run = TranslationRun.create!(:game => game, :actor => superadmin,
                                 :model => "claude-opus-5", :state => TranslationRun::SUCCEEDED)
    sign_in(superadmin)

    get game_translation_run_path(game, run)

    expect(response.body).not_to include(I18n.t("translations.show.estimate"))
  end

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
