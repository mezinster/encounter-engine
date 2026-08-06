# -*- encoding : utf-8 -*-
require "rails_helper"

# Task 9c: real ERB compilation for the 3 users/* templates in scope
# (users/show.html.erb is out of scope -- it's an unrouted debug leftover
# with no Merb helper calls, see task-9c-report.md).
RSpec.describe "users/edit", type: :view do
  it "renders the profile-edit form, preserving the pre-existing text_field (not password_field) quirk" do
    user = create_user

    assign(:current_user, user)
    assign(:user, user)

    render

    expect(rendered).to include(I18n.t("users.edit.title", nickname: user.nickname))
    expect(rendered).to include(I18n.t("users.edit.nickname_label"))
    expect(rendered).to include(I18n.t("users.edit.date_of_birth_label"))
    expect(rendered).to include(I18n.t("users.edit.icq_label"))
    expect(rendered).to include(I18n.t("users.edit.jabber_label"))
    expect(rendered).to include(I18n.t("users.edit.instagram_label"))
    expect(rendered).to include(I18n.t("users.edit.telegram_label"))
    expect(rendered).to include(I18n.t("users.edit.messengers_label"))
    expect(rendered).to include(I18n.t("messengers.signal"))
    expect(rendered).to include(I18n.t("users.edit.password_label"))
    expect(rendered).to include(I18n.t("users.edit.password_confirmation_label"))
    expect(rendered).to include(I18n.t("users.edit.submit"))
    expect(rendered).to include(ERB::Util.html_escape(I18n.t("shared.cancel")))
    expect(rendered).to include(users_path)
    # The Merb original used text_field (not password_field) for both
    # password inputs on this form -- a pre-existing quirk (plaintext
    # visible password), preserved exactly rather than "fixed" by this port.
    expect(rendered).to include('type="text" value="1234" name="user[password]"')
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
    expect(rendered).to include(I18n.t("users.index.icq_label"))
    expect(rendered).to include(I18n.t("users.index.jabber_label"))
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
    expect(rendered).to include(I18n.t("users.new.password_label"))
    expect(rendered).to include(I18n.t("users.new.password_confirmation_label"))
    expect(rendered).to include(I18n.t("users.new.submit"))
    expect(rendered).to include(users_path)
  end

  it "renders validation errors with the shared error header" do
    user = User.new
    user.valid?
    assign(:user, user)

    render

    expect(rendered).to include(I18n.t("shared.error_header"))
  end
end
