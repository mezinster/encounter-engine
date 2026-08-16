require "rails_helper"

describe "the superadmin settings screen", type: :request do
  let(:superadmin) do
    u = create_user
    u.update!(:is_superadmin => true)
    u
  end
  let(:ordinary) { create_user }

  def login_as(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "refuses an ordinary user" do
    login_as(ordinary)
    get admin_settings_path

    expect(response).not_to have_http_status(:ok)
  end

  it "refuses a signed-out visitor" do
    get admin_settings_path

    expect(response).not_to have_http_status(:ok)
  end

  it "shows the current values to a superadmin" do
    Setting.put("signup_max", 9)
    login_as(superadmin)
    get admin_settings_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("9")
  end

  it "stores a changed limit" do
    login_as(superadmin)

    patch admin_settings_path, :params => { :settings => { "signup_max" => "12" } }

    expect(Setting.integer("signup_max")).to eq(12)
  end

  it "records the change in the audit log" do
    login_as(superadmin)

    expect {
      patch admin_settings_path, :params => { :settings => { "reset_max" => "7" } }
    }.to change { AdminAction.where(:action => "update_settings").count }.by(1)

    entry = AdminAction.where(:action => "update_settings").last
    expect(entry.actor_id).to eq(superadmin.id)
    expect(entry.details).to include("reset_max")
  end

  # A rejected value must not be written, and must not be reported as saved --
  # an operator who believes a limit is 0 when it is still 5 will not
  # understand why the console is still refusing signups.
  it "refuses a negative value without writing it" do
    login_as(superadmin)

    patch admin_settings_path, :params => { :settings => { "signup_max" => "-3" } }

    expect(Setting.integer("signup_max")).to eq(Setting::DEFAULTS.fetch("signup_max"))
    expect(response).to have_http_status(:unprocessable_entity)
  end

  # The controller slices submitted keys against the permitted key list.
  # Asserting only that an unknown key creates no row does NOT test that slice -- the
  # model's own inclusion validation already refuses it, so such an example
  # passes with the slice deleted (confirmed by mutation). What the slice
  # actually changes is the fate of the REST of the submission: with it, the
  # unknown key is dropped and the valid keys save; without it, Setting.put
  # raises, the transaction rolls back, and a stray parameter silently
  # discards a legitimate change while blaming the operator's value.
  it "ignores an unknown name while still saving the known ones" do
    login_as(superadmin)

    patch admin_settings_path, :params => { :settings => { "signup_max" => "11", "wat" => "1" } }

    expect(Setting.integer("signup_max")).to eq(11)
    expect(Setting.where(:name => "wat")).to be_empty
    expect(response).to have_http_status(:found)
  end

  it "shows the storage settings to a superadmin" do
    login_as(superadmin)

    get admin_settings_path

    expect(response.body).to include("settings_game_quota_megabytes")
    expect(response.body).to include("settings_allowed_extensions")
  end

  # Regression: current_values used to merge ENUM_DEFAULTS into the same hash
  # the number-field loop iterates, so translation_model rendered TWICE --
  # once as a number_field_tag holding a model name, once as the correct
  # select_tag -- both sharing id="settings_translation_model". Nothing above
  # asserted uniqueness, so a substring `include` check would pass either
  # way; only counting the actual elements catches it.
  it "renders exactly one control for the translation model, as a select" do
    login_as(superadmin)

    get admin_settings_path

    matches = Nokogiri::HTML(response.body).css("#settings_translation_model")

    expect(matches.size).to eq(1)
    expect(matches.first.name).to eq("select")
    expect(response.body).not_to include('type="number" name="settings[translation_model]"')
  end

  it "stores a changed extension list" do
    login_as(superadmin)

    patch admin_settings_path, :params => { :settings => { "allowed_extensions" => "jpg pdf" } }

    expect(Setting.list("allowed_extensions")).to eq(%w[jpg pdf])
  end

  it "refuses a malformed extension list without writing it" do
    login_as(superadmin)
    Setting.put("allowed_extensions", "jpg pdf")

    patch admin_settings_path, :params => { :settings => { "allowed_extensions" => "jpg ../etc" } }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(Setting.list("allowed_extensions")).to eq(%w[jpg pdf])
  end
end
