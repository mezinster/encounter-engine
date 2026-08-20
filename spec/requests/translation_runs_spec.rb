require "rails_helper"

describe "starting a translation run", type: :request do
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:game)       { create_game(:primary_locale => "ru", :available_locale_list => %w[ru]) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  before do
    create_level(:game => game, :name => "Первый", :text => "Найдите табличку")
    allow(Translation::Client).to receive(:configured?).and_return(true)
    # The thread is not started in specs; the run's creation is what is under
    # test here, and the runner has its own spec.
    allow(Translation::Runner).to receive(:new).and_return(double(:call => nil))
    # The pre-flight goes through the SDK. Stubbed at the same seam the
    # controller calls, so no example here can reach the network.
    allow(Translation::Runner).to receive(:estimate_input_tokens).and_return(4_321)
    sign_in(superadmin)
  end

  # The cost guard: the first POST spends nothing and creates nothing, it only
  # prices the work. Without this the edit screen's one-click button started
  # spending immediately and estimated_input_tokens was a dead column.
  it "prices the run and creates nothing until the operator confirms" do
    expect { post game_translation_runs_path(game), :params => { :locales => %w[en pl] } }
      .not_to change { TranslationRun.count }

    expect(response.body).to include(I18n.t("translations.confirm.submit"))
    # Through the same helper the view uses -- ru groups with a space, not a
    # comma, so a hard-coded "4,321" would be asserting the wrong locale.
    expect(response.body)
      .to include(ActionController::Base.helpers.number_with_delimiter(4_321))
    # The measured figure, and the locales, carried into the second POST.
    expect(response.body).to include('name="confirmed"')
    expect(response.body).to include('value="4321"')
    expect(response.body).to include('value="en"')
  end

  it "stores the measured estimate on the run it starts" do
    post game_translation_runs_path(game),
         :params => { :locales => %w[en pl], :confirmed => "1",
                      :estimated_input_tokens => "4321" }

    expect(TranslationRun.newest_first.first.estimated_input_tokens).to eq(4_321)
  end

  # A free, informational pre-flight must not be able to block the feature.
  it "still offers to run when the pre-flight itself fails" do
    allow(Translation::Runner).to receive(:estimate_input_tokens)
      .and_raise(Translation::Client::Error, "429")

    post game_translation_runs_path(game), :params => { :locales => [ "en" ] }

    expect(response.body).to include(I18n.t("translations.confirm.estimate_unknown"))
    expect(response.body).to include(I18n.t("translations.confirm.submit"))
  end

  it "creates a run carrying the model resolved at start time" do
    Setting.put("translation_model", "claude-sonnet-5")

    expect {
      post game_translation_runs_path(game),
           :params => { :locales => %w[en pl], :confirmed => "1" }
    }.to change { TranslationRun.count }.by(1)

    run = TranslationRun.newest_first.first
    expect(run.model).to eq("claude-sonnet-5")
    expect(run.target_locale_list).to eq(%w[en pl])
    expect(run.fields_total).to be > 0
    expect(response).to redirect_to(game_translation_run_path(game, run))
  end

  it "refuses a second run while one is already in flight" do
    TranslationRun.create!(:game => game, :actor => superadmin, :model => "claude-opus-5",
                           :state => TranslationRun::RUNNING)

    expect { post game_translation_runs_path(game), :params => { :locales => [ "en" ] } }
      .not_to change { TranslationRun.count }

    expect(flash[:alert]).to eq(I18n.t("translations.runs.already_running"))
  end

  # The database, not the controller, is what actually enforces this. The
  # controller's TranslationRun.active_for(@game).exists? check is
  # check-then-act and cannot, on its own, stop two concurrent POSTs.
  it "cannot create a second active run for the same game at the database level" do
    TranslationRun.create!(:game => game, :actor => superadmin,
                           :model => "claude-opus-5", :state => TranslationRun::RUNNING)

    expect {
      TranslationRun.create!(:game => game, :actor => superadmin,
                             :model => "claude-opus-5", :state => TranslationRun::PENDING)
    }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  # A terminal run must not block a new one -- the index is partial for
  # exactly this reason.
  it "allows a new run once the previous one is terminal" do
    TranslationRun.create!(:game => game, :actor => superadmin,
                           :model => "claude-opus-5", :state => TranslationRun::SUCCEEDED)

    expect {
      post game_translation_runs_path(game),
           :params => { :locales => [ "en" ], :confirmed => "1" }
    }.to change { TranslationRun.count }.by(1)
  end

  # Losing the race must refuse the same way the guard does, not 500.
  it "refuses gracefully when the database wins the race" do
    # Simulate the interleaving: the guard sees nothing, then a row appears
    # before our insert.
    allow(TranslationRun).to receive(:active_for).and_return(TranslationRun.none)
    TranslationRun.create!(:game => game, :actor => superadmin,
                           :model => "claude-opus-5", :state => TranslationRun::RUNNING)

    expect {
      post game_translation_runs_path(game),
           :params => { :locales => [ "en" ], :confirmed => "1" }
    }.not_to change { TranslationRun.count }
    expect(flash[:alert]).to eq(I18n.t("translations.runs.already_running"))
  end

  it "refuses a run larger than the configured cap" do
    Setting.put("translation_max_fields_per_run", 1)

    expect { post game_translation_runs_path(game), :params => { :locales => %w[en pl] } }
      .not_to change { TranslationRun.count }

    expect(flash[:alert]).to be_present
  end

  # The reported bug: a ~70-level quiz is ~492 fields at ONE language -- the cap
  # is checked against Runner.plan's output, which is fields x locales -- and it
  # was refused outright. The work-list is stubbed rather than built, because
  # creating 500 records to exercise one integer comparison is a slow way to
  # assert nothing extra; estimate_input_tokens is already stubbed for this
  # whole file, so no network is involved either.
  it "no longer refuses a game that is merely large" do
    allow(Translation::Runner).to receive(:plan).and_return(Array.new(492, :field))

    # Still creates nothing: an unconfirmed POST prices the work and stops,
    # which is the behaviour being asserted.
    expect { post game_translation_runs_path(game), :params => { :locales => %w[en] } }
      .not_to change { TranslationRun.count }

    expect(flash[:alert]).to be_nil
    expect(response.body).to include(I18n.t("translations.confirm.submit"))
  end

  it "refuses a run with nothing to do" do
    expect { post game_translation_runs_path(game), :params => { :locales => [ "ru" ] } }
      .not_to change { TranslationRun.count }
  end

  it "lets a superadmin cancel a running run" do
    run = TranslationRun.create!(:game => game, :actor => superadmin,
                                 :model => "claude-opus-5", :state => TranslationRun::RUNNING)

    post cancel_game_translation_run_path(game, run)

    expect(run.reload.state).to eq(TranslationRun::CANCELLED)
  end

  # Cancelling a finished run destroys the terminal record and audits a
  # cancellation that cancelled nothing. TranslationRun#terminal? already
  # existed; nothing consulted it here.
  it "refuses to cancel a run that has already finished" do
    run = TranslationRun.create!(:game => game, :actor => superadmin,
                                 :model => "claude-opus-5",
                                 :state => TranslationRun::SUCCEEDED,
                                 :finished_at => 1.hour.ago)
    was_finished_at = run.finished_at

    expect { post cancel_game_translation_run_path(game, run) }
      .not_to change { AdminAction.count }

    expect(run.reload.state).to eq(TranslationRun::SUCCEEDED)
    expect(run.finished_at.to_i).to eq(was_finished_at.to_i)
    expect(flash[:alert]).to eq(I18n.t("translations.runs.already_finished"))
  end

  # THE C2 half that turned a latent bug into a guaranteed one. show is the
  # page whose <meta refresh> reloads every three seconds; with the sweep
  # unqualified, the operator's own progress page failed their healthy run
  # fifteen minutes in, and `failed` is not an ACTIVE_STATE, so the partial
  # unique index released and a second concurrent run became possible.
  it "does not sweep stale runs from the progress page" do
    run = TranslationRun.create!(:game => game, :actor => superadmin,
                                 :model => "claude-opus-5",
                                 :state => TranslationRun::RUNNING)
    run.update_column(:updated_at, 30.minutes.ago)

    get game_translation_run_path(game, run)

    expect(run.reload.state).to eq(TranslationRun::RUNNING)
  end

  # The run page is the only place anyone sees whether the caching design is
  # earning its keep, and until now it showed only the READ. A run that wrote a
  # large prefix and never read it back -- the shape every production run had
  # -- rendered identically to a run that cached nothing, because input_tokens
  # reports the uncached remainder alone.
  #
  # Asserting the literal Russian rather than I18n.t(...): a missing key makes
  # `include(I18n.t(key))` compare a translation-missing string against itself
  # and pass, so the interpolation could vanish with the spec still green.
  it "shows what a run wrote to the cache, not only what it read" do
    run = TranslationRun.create!(:game => game, :actor => superadmin,
                                 :model => "claude-opus-5",
                                 :state => TranslationRun::SUCCEEDED,
                                 :input_tokens => 1_365, :output_tokens => 13_657,
                                 :cache_write_tokens => 41_502, :cache_read_tokens => 0)

    get game_translation_run_path(game, run)

    expect(response.body).to include("в кэш 41502, из кэша 0")
  end

  it "still sweeps stale runs when someone tries to start a new one" do
    stale = TranslationRun.create!(:game => game, :actor => superadmin,
                                   :model => "claude-opus-5",
                                   :state => TranslationRun::RUNNING)
    stale.update_column(:updated_at, 30.minutes.ago)

    get new_game_translation_run_path(game)

    expect(stale.reload.state).to eq(TranslationRun::FAILED)
  end

  describe "retrying a run" do
    def run_in(state)
      TranslationRun.create!(:game => game, :actor => superadmin, :model => "claude-opus-5",
                             :state => state, :target_locale_list => %w[en],
                             :fields_total => 4, :fields_done => 3)
    end

    it "re-enters a failed run rather than creating a second one" do
      run = run_in(TranslationRun::FAILED)

      expect { post retry_game_translation_run_path(game, run) }
        .not_to change { TranslationRun.count }

      expect(response).to redirect_to(game_translation_run_path(game, run))
      expect(AdminAction.newest_first.first.action).to eq("translation_run_retried")
    end

    it "refuses to retry a run that is still active" do
      run = run_in(TranslationRun::RUNNING)

      expect { post retry_game_translation_run_path(game, run) }
        .not_to change { AdminAction.count }
      expect(flash[:alert]).to eq(I18n.t("translations.runs.not_retryable"))
    end

    it "refuses to retry a succeeded run" do
      run = run_in(TranslationRun::SUCCEEDED)

      post retry_game_translation_run_path(game, run)
      expect(flash[:alert]).to eq(I18n.t("translations.runs.not_retryable"))
    end

    # Deliberate, and it is a decision rather than an oversight: cancelling is
    # a human saying stop, and a button that silently restarts it would make
    # the stop unreliable.
    it "refuses to retry a cancelled run" do
      run = run_in(TranslationRun::CANCELLED)

      post retry_game_translation_run_path(game, run)
      expect(flash[:alert]).to eq(I18n.t("translations.runs.not_retryable"))
    end
  end
end
