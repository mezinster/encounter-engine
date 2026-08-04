# -*- encoding : utf-8 -*-
require "rails_helper"

# Task 9c: real ERB compilation for invitations/new.html.erb.
RSpec.describe "invitations/new", type: :view do
  it "renders the invite form and the autocomplete data for other users" do
    current_user = create_user
    other_user = create_user
    invitation = Invitation.new(to_team: create_team(captain: current_user))

    assign(:current_user, current_user)
    assign(:all_users, [current_user, other_user])
    assign(:invitation, invitation)
    view.define_singleton_method(:current_user) { current_user }

    render

    expect(rendered).to include(I18n.t("invitations.new.recipient_label"))
    expect(rendered).to include(I18n.t("invitations.new.submit"))
    expect(rendered).to include(invitations_path)
    # The current user is excluded from the autocomplete data (Merb's
    # `if user != @current_user`); the other user is included.
    expect(rendered).to include(other_user.nickname)
    expect(rendered).not_to include("nick: '#{current_user.nickname}'")
  end

  it "renders validation errors with the helper's default (untranslated) header, per the preserved Merb quirk" do
    # error_messages_for @invitation has no :header override in the Merb
    # original (unlike every other form in this port) -- it falls through
    # to GlobalHelpers#error_messages_for's own English default header,
    # which is preserved here, not "fixed" with a Russian one.
    invitation = Invitation.new
    invitation.valid?

    assign(:current_user, create_user)
    assign(:all_users, [])
    assign(:invitation, invitation)

    render

    expect(rendered).to include("Form submission failed because of")
  end
end
