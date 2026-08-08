# -*- encoding : utf-8 -*-
require "rails_helper"

# Task 9c: real ERB compilation for the 3 users/* templates in scope
# (users/show.html.erb is out of scope -- it's an unrouted debug leftover
# with no Merb helper calls, see task-9c-report.md).
RSpec.describe "users/edit", type: :view do
  it "renders the profile-edit form" do
    user = create_user

    assign(:current_user, user)
    assign(:user, user)

    render

    expect(rendered).to include(I18n.t("users.edit.title", nickname: user.nickname))
    expect(rendered).to include(I18n.t("users.edit.nickname_label"))
    expect(rendered).to include(I18n.t("users.edit.date_of_birth_label"))
    expect(rendered).to include(I18n.t("users.edit.instagram_label"))
    expect(rendered).to include(I18n.t("users.edit.telegram_label"))
    expect(rendered).to include(I18n.t("users.edit.messengers_label"))
    expect(rendered).to include(I18n.t("messengers.signal"))
    expect(rendered).to include(I18n.t("users.edit.current_password"))
    expect(rendered).to include(I18n.t("users.edit.password_label"))
    expect(rendered).to include(I18n.t("users.edit.password_confirmation_label"))
    expect(rendered).to include(I18n.t("users.edit.submit"))
    expect(rendered).to include(ERB::Util.html_escape(I18n.t("shared.cancel")))
    expect(rendered).to include(users_path)
    # The Merb original used text_field (not password_field) for both
    # password inputs on this form -- a pre-existing quirk (plaintext
    # visible password). CWE-620 remediation (task 2,
    # 2026-08-07-security-account-protection) switched both to password_field
    # and added a current_password field, none of which round-trip a value,
    # so the rendered inputs are empty regardless of the user's stored password.
    expect(rendered).to include('type="password" name="user[current_password]"')
    expect(rendered).to include('type="password" name="user[password]"')
    expect(rendered).to include('type="password" name="user[password_confirmation]"')
  end

  # Label text alone doesn't prove the input is wired to the attribute --
  # a disconnected check_box_tag would render the same label and still
  # never submit user[on_signal] at all.
  it "submits the new fields under the attribute names profile_params expects" do
    user = create_user

    assign(:current_user, user)
    assign(:user, user)

    render

    expect(rendered).to include('name="user[instagram]"')
    expect(rendered).to include('name="user[telegram_id]"')
    expect(rendered).to include('name="user[on_telegram]"')
    expect(rendered).to include('name="user[on_whatsapp]"')
    expect(rendered).to include('name="user[on_viber]"')
    expect(rendered).to include('name="user[on_signal]"')
    expect(rendered).to include('name="user[on_max]"')
  end

  # The name= assertions above pin SUBMISSION wiring but not checked-state
  # fidelity: a `check_box_tag "user[on_signal]", "1", false` posts under the
  # right key and passes every one of them, while always rendering unchecked.
  # A player with the flag set would open this form, see the box empty, save,
  # and silently turn the setting off. Only `f.check_box` reads the stored
  # value back, and this is what proves it does.
  it "renders each messenger checkbox checked to match the stored value" do
    user = create_user
    user.update!(:on_signal => true, :on_viber => false)

    assign(:current_user, user)
    assign(:user, user)

    render

    # type="checkbox" is load-bearing in these patterns: f.check_box emits a
    # hidden input with the SAME name first, so an unchecked box still submits
    # "0". Matching on the name alone finds that hidden field, which never
    # carries `checked`, and the example would fail against correct code.
    signal = rendered[/<input[^>]*type="checkbox"[^>]*name="user\[on_signal\]"[^>]*>/]
    viber  = rendered[/<input[^>]*type="checkbox"[^>]*name="user\[on_viber\]"[^>]*>/]

    expect(signal).to be_present, "no checkbox input found for on_signal"
    expect(viber).to be_present,  "no checkbox input found for on_viber"

    expect(signal).to include("checked")
    expect(viber).not_to include("checked")
  end

  it "shows the phone number field only for a captain" do
    captain_user = create_user
    create_team(captain: captain_user)
    captain_user.reload

    assign(:current_user, captain_user)
    assign(:user, captain_user)

    render

    expect(rendered).to include(I18n.t("users.edit.phone_label"))
  end
end

RSpec.describe "users/index", type: :view do
  it "shows the current user's profile fields" do
    user = create_user

    assign(:current_user, user)
    view.define_singleton_method(:current_user) { user }

    render

    expect(rendered).to include(I18n.t("users.index.title"))
    expect(rendered).to include(user.nickname)
    expect(rendered).to include(I18n.t("users.index.email_label"))
    expect(rendered).to include(user.email)
    expect(rendered).to include(I18n.t("users.index.date_of_birth_label"))
    expect(rendered).to include(ERB::Util.html_escape(I18n.t("users.index.edit_link")))
    expect(rendered).to include(edit_user_path(user))
    expect(rendered).not_to include(I18n.t("users.index.captain_prefix"))
  end

  it "shows the captain badge and team room link for a captain" do
    captain_user = create_user
    team = create_team(captain: captain_user)
    captain_user.reload

    assign(:current_user, captain_user)
    view.define_singleton_method(:current_user) { captain_user }

    render

    expect(rendered).to include(I18n.t("users.index.captain_prefix"))
    expect(rendered).to include(team.name)
    expect(rendered).to include(team_room_path)
    expect(rendered).to include(I18n.t("users.index.phone_label"))
  end

  it "renders contact handles as links and lists only the ticked messengers" do
    user = create_user
    user.update!(:instagram => "@player", :telegram_id => "player",
                 :on_signal => true, :on_viber => true)

    assign(:current_user, user)
    view.define_singleton_method(:current_user) { user }

    render

    # Normalised on save, so the link is built from a bare handle.
    expect(rendered).to include("https://instagram.com/player")
    expect(rendered).to include("https://t.me/player")
    expect(rendered).to include(I18n.t("messengers.signal"))
    expect(rendered).to include(I18n.t("messengers.viber"))
    expect(rendered).not_to include(I18n.t("messengers.whatsapp"))
  end

  it "omits the contact rows entirely when nothing is filled in" do
    user = create_user

    assign(:current_user, user)
    view.define_singleton_method(:current_user) { user }

    render

    expect(rendered).not_to include(I18n.t("users.index.instagram_label"))
    expect(rendered).not_to include(I18n.t("users.index.messengers_label"))
  end
end

RSpec.describe "users/new", type: :view do
  it "renders the signup form" do
    assign(:user, User.new)

    render

    expect(rendered).to include(I18n.t("users.new.nickname_label"))
    expect(rendered).to include(I18n.t("users.new.email_label"))
    expect(rendered).to include(I18n.t("users.new.submit"))
    expect(rendered).to include(users_path)
  end

  # Product decision 2026-08-08 (see CLAUDE.md, "The acceptance-suite rule"):
  # signup collects nickname and email only -- the server generates the first
  # password (UsersController#create) -- so the form must not offer fields
  # that could never do anything but be silently dropped by signup_params.
  it "does not offer password fields" do
    assign(:user, User.new)

    render

    expect(rendered).not_to include('name="user[password]"')
    expect(rendered).not_to include('name="user[password_confirmation]"')
  end

  it "renders validation errors with the shared error header" do
    user = User.new
    user.valid?
    assign(:user, user)

    render

    expect(rendered).to include(I18n.t("shared.error_header"))
  end
end
