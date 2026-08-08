require "rails_helper"

# S5 of docs/superpowers/specs/2026-08-08-team-membership-programme-design.md.
# Housekeeping -- spam and test accounts. Every refusal below exists because
# the alternative damages something the deleted user does not own.
describe "deleting a user account", type: :request do
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }
  # A second superadmin, so the last-superadmin guard is not what refuses the
  # ordinary cases.
  let!(:spare_admin) { u = create_user; u.update!(:is_superadmin => true); u }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "deletes a plain user and records who did it" do
    victim = create_user
    sign_in(superadmin)

    expect do
      delete destroy_admin_user_path(victim)
    end.to change(User, :count).by(-1)

    expect(User.find_by(:id => victim.id)).to be_nil
    expect(response).to redirect_to(admin_users_path)
    entry = AdminAction.newest_first.first
    expect(entry.action).to eq("delete_user")
    # The label is the whole point: target_id now points at nothing.
    expect(entry.target_label).to eq(victim.nickname)
  end

  # Refusal 1, mirroring cannot_revoke_self: an operator deleting themselves
  # mid-session.
  it "refuses to delete yourself" do
    sign_in(superadmin)

    expect do
      delete destroy_admin_user_path(superadmin)
    end.not_to change(User, :count)

    expect(flash[:alert]).to eq(I18n.t("admin.users.cannot_delete_self"))
  end

  # Refusal 2: their team would be left captainless with members -- the
  # bricked state this whole programme exists to remove.
  it "refuses to delete a captain" do
    captain = create_user
    create_team(:captain => captain)
    sign_in(superadmin)

    delete destroy_admin_user_path(captain)

    expect(flash[:alert]).to eq(I18n.t("admin.users.cannot_delete_captain"))
  end

  it "leaves a captain and their team intact when refused" do
    captain = create_user
    team = create_team(:captain => captain)
    sign_in(superadmin)

    delete destroy_admin_user_path(captain)

    expect(User.find_by(:id => captain.id)).not_to be_nil
    expect(team.reload.captain).to eq(captain)
  end

  # Refusal 3, the last-superadmin guard, has NO example here, deliberately,
  # and the reasoning is worth writing down rather than leaving as a gap.
  #
  # The design asked for last_superadmin_keeps_the_role to be mirrored onto
  # destroy, since that validation guards REVOKING the role and destroy walks
  # past it. But the guard turns out to be unreachable through this
  # controller: require_superadmin! means the actor is a superadmin, so
  # deleting anyone else always leaves at least the actor, and deleting
  # oneself is refused by the self guard above. There is no request that both
  # passes those two and empties the role.
  #
  # The guard is implemented anyway, as the comment on it explains -- it
  # costs one comparison and it is the only thing standing between a future
  # removal of the self guard and an instance nobody can administer. It is
  # simply not something a controller spec can exercise today, and writing an
  # example that contorts the fixtures until it "passes" would be testing the
  # contortion, not the guard.
  it "still refuses to delete a superadmin who is the only one, via the self guard" do
    spare_admin.destroy
    sign_in(superadmin)

    expect do
      delete destroy_admin_user_path(superadmin)
    end.not_to change(User, :count)

    expect(User.superadmin_count).to eq(1)
  end

  # Refusal 4: games are content other people played. Orphaning them also
  # 500s games/show.html.erb, which dereferences @game.author.nickname
  # unguarded.
  it "refuses to delete a user who authored games" do
    author = create_user
    create_game(:author => author)
    sign_in(superadmin)

    delete destroy_admin_user_path(author)

    expect(flash[:alert]).to eq(I18n.t("admin.users.cannot_delete_author"))
  end

  it "leaves the author and their games intact when refused" do
    author = create_user
    game = create_game(:author => author)
    sign_in(superadmin)

    delete destroy_admin_user_path(author)

    expect(User.find_by(:id => author.id)).not_to be_nil
    expect(Game.find_by(:id => game.id)).not_to be_nil
  end

  describe "the control on the user page" do
    it "is offered for a deletable user, as a DELETE form" do
      victim = create_user
      sign_in(superadmin)

      get admin_user_path(victim)

      # Two steps rather than one ordered regex: button_to emits action before
      # method, and the verb rides a hidden _method field, not the form tag.
      form_tag = response.body[
        %r{<form[^>]*action="#{Regexp.escape(destroy_admin_user_path(victim))}"[^>]*>}
      ]
      expect(form_tag).not_to be_nil
      expect(response.body).to include('name="_method" value="delete"')
    end

    # Offering it would be a promise the action refuses to keep. Each of the
    # three is a case #destroy declines.
    it "is not offered for yourself, a captain, or an author" do
      captain = create_user
      create_team(:captain => captain)
      author = create_user
      create_game(:author => author)
      sign_in(superadmin)

      [superadmin, captain, author].each do |undeletable|
        get admin_user_path(undeletable)
        expect(response.body).not_to include(destroy_admin_user_path(undeletable))
      end
    end
  end

  it "refuses an ordinary signed-in user" do
    victim = create_user
    sign_in(create_user)

    expect do
      delete destroy_admin_user_path(victim)
    end.not_to change(User, :count)

    expect(response).to have_http_status(:unauthorized)
  end

  it "refuses an anonymous visitor" do
    victim = create_user

    expect do
      delete destroy_admin_user_path(victim)
    end.not_to change(User, :count)

    expect(response).to redirect_to(login_path)
  end
end
