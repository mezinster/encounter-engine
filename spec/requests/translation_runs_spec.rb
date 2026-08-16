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
    sign_in(superadmin)
  end

  it "creates a run carrying the model resolved at start time" do
    Setting.put("translation_model", "claude-sonnet-5")

    expect { post game_translation_runs_path(game), :params => { :locales => %w[en pl] } }
      .to change { TranslationRun.count }.by(1)

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

  it "refuses a run larger than the configured cap" do
    Setting.put("translation_max_fields_per_run", 1)

    expect { post game_translation_runs_path(game), :params => { :locales => %w[en pl] } }
      .not_to change { TranslationRun.count }

    expect(flash[:alert]).to be_present
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
end
