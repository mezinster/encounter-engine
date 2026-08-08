require "rails_helper"

# S6 of docs/superpowers/specs/2026-08-08-team-membership-programme-design.md.
# The other half of D4: identity goes, the row stays.
#
# The authored-games example below is the whole reason both operations exist.
# Hard deletion refuses an author, because orphaning their games 500s
# games/show.html.erb. Anonymisation keeps the row, so the games survive with
# a scrubbed author -- which is what makes a game author removable at all.
describe "anonymising a user account", type: :request do
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }
  let!(:spare_admin) { u = create_user; u.update!(:is_superadmin => true); u }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "scrubs identity but keeps the row" do
    victim = create_user
    victim.update!(:phone_number => "+7 900 000-00-00", :instagram => "someone",
                   :telegram_id => "someone", :date_of_birth => "1990-01-01")
    sign_in(superadmin)

    post anonymise_admin_user_path(victim)

    victim.reload
    expect(victim.nickname).to eq("удалённый-#{victim.id}")
    expect(victim.email).to eq("deleted-#{victim.id}@example.invalid")
    expect(victim.phone_number).to be_blank
    expect(victim.instagram).to be_blank
    expect(victim.telegram_id).to be_blank
    expect(victim.date_of_birth).to be_nil
  end

  it "detaches them from their team and revokes any admin rights" do
    victim = create_user
    team = create_team(:captain => create_user)
    team.members << victim
    victim.update!(:is_superadmin => true)
    sign_in(superadmin)

    post anonymise_admin_user_path(victim)

    expect(victim.reload.team).to be_nil
    expect(victim.superadmin?).to be false
  end

  it "records who did it" do
    victim = create_user
    sign_in(superadmin)

    post anonymise_admin_user_path(victim)

    entry = AdminAction.newest_first.first
    expect(entry.action).to eq("anonymise_user")
    expect(entry.target_id).to eq(victim.id)
  end

  # THE distinguishing property. A hard delete refuses this user entirely;
  # anonymisation is how they are removed without destroying games other
  # people played.
  it "keeps an authored game readable afterwards" do
    author = create_user
    game = create_game(:author => author, :is_draft => false)
    sign_in(superadmin)

    post anonymise_admin_user_path(author)

    get game_path(game)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("удалённый-#{author.id}")
  end

  it "refuses to anonymise yourself" do
    sign_in(superadmin)

    post anonymise_admin_user_path(superadmin)

    expect(superadmin.reload.nickname).not_to start_with("удалённый-")
    expect(flash[:alert]).to eq(I18n.t("admin.users.cannot_anonymise_self"))
  end

  # Their team would be left with a captain who cannot log in and has no
  # name -- bricked in all but the column.
  it "refuses to anonymise a captain" do
    captain = create_user
    create_team(:captain => captain)
    sign_in(superadmin)

    post anonymise_admin_user_path(captain)

    expect(flash[:alert]).to eq(I18n.t("admin.users.cannot_anonymise_captain"))
  end

  it "leaves a captain's identity intact when refused" do
    captain = create_user
    create_team(:captain => captain)
    original = captain.nickname
    sign_in(superadmin)

    post anonymise_admin_user_path(captain)

    expect(captain.reload.nickname).to eq(original)
  end

  describe "the control on the user page" do
    # Unlike delete, this IS offered for an author -- that is the whole point
    # of having both operations.
    it "is offered for an author, as a POSTing form" do
      author = create_user
      create_game(:author => author)
      sign_in(superadmin)

      get admin_user_path(author)

      form_tag = response.body[
        %r{<form[^>]*action="#{Regexp.escape(anonymise_admin_user_path(author))}"[^>]*>}
      ]
      expect(form_tag).not_to be_nil
      expect(form_tag).to include('method="post"')
    end

    it "is not offered for yourself or a captain" do
      captain = create_user
      create_team(:captain => captain)
      sign_in(superadmin)

      [superadmin, captain].each do |untouchable|
        get admin_user_path(untouchable)
        expect(response.body).not_to include(anonymise_admin_user_path(untouchable))
      end
    end
  end

  it "refuses an ordinary signed-in user" do
    victim = create_user
    original = victim.nickname
    sign_in(create_user)

    post anonymise_admin_user_path(victim)

    expect(victim.reload.nickname).to eq(original)
    expect(response).to have_http_status(:unauthorized)
  end

  it "refuses an anonymous visitor" do
    victim = create_user
    original = victim.nickname

    post anonymise_admin_user_path(victim)

    expect(victim.reload.nickname).to eq(original)
    expect(response).to redirect_to(login_path)
  end
end
