require "rails_helper"

# The superadmin's user page, regrouped into sections: profile, roles, team,
# account. Every control keeps the condition Admin::UsersController enforces.
describe "the superadmin's user page", type: :request do
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def doc
    Nokogiri::HTML(response.body)
  end

  def section(key)
    doc.at_css(".admin-user .sheet-section--#{key}")
  end

  it "groups the page into profile, roles, team and account, in that order" do
    target = create_user
    create_team(:captain => create_user).members << target
    create_team(:captain => create_user) # a destination, or the move panel is rightly absent
    sign_in(superadmin)
    get admin_user_path(target)

    expect(doc.css(".admin-user .sheet-section").map { |s| s["class"][/sheet-section--(\w+)/, 1] })
      .to eq(%w[profile roles team account])
    expect(section("profile").css(".fact-label").map { |l| l.text.strip }).to include("E-mail", "Команда", "Регистрация")
  end

  it "shows role tags beside the name" do
    target = create_user
    target.update!(:is_superadmin => true, :is_operator => true)
    sign_in(superadmin)
    get admin_user_path(target)

    expect(doc.css(".admin-user h1 + .admin-user-roles .tag").map(&:text)).to eq(%w[администратор оператор])
  end

  it "grants with the filled button and revokes with a plain one" do
    target = create_user
    target.update!(:is_operator => true)
    sign_in(superadmin)
    get admin_user_path(target)

    grant  = section("roles").at_css("form[action='#{grant_admin_user_path(target)}'] button")
    revoke = section("roles").at_css("form[action='#{revoke_operator_admin_user_path(target)}'] button")
    expect(grant["class"]).to include("btn--go")
    expect(revoke["class"].split).to eq(%w[btn])
    expect(section("roles").css(".role-hint").size).to eq(2)
  end

  it "offers anonymise and delete, with their explanations, for a plain user" do
    target = create_user
    sign_in(superadmin)
    get admin_user_path(target)

    account = section("account")
    expect(account.at_css("form[action='#{anonymise_admin_user_path(target)}']")).not_to be_nil
    expect(account.at_css("form[action='#{destroy_admin_user_path(target)}'] button")["class"]).to include("btn--danger")
    expect(account.css(".role-hint").size).to eq(2)
  end

  it "never offers anonymise or delete on your own page" do
    sign_in(superadmin)
    get admin_user_path(superadmin)

    expect(response.body).not_to include(anonymise_admin_user_path(superadmin))
    expect(response.body).not_to include(destroy_admin_user_path(superadmin))
    expect(section("account")).to be_nil
  end

  it "offers an author anonymise but not delete" do
    target = create_user
    create_game(:author => target)
    sign_in(superadmin)
    get admin_user_path(target)

    expect(section("account").to_html).to include(anonymise_admin_user_path(target))
    expect(section("account").to_html).not_to include(destroy_admin_user_path(target))
  end

  it "offers a captain neither the move nor the account actions" do
    captain = create_user
    create_team(:captain => captain)
    create_team(:captain => create_user)
    sign_in(superadmin)
    get admin_user_path(captain)

    expect(section("team")).to be_nil
    expect(section("account")).to be_nil
  end
end
