require "rails_helper"

# Literal Russian rather than I18n.t: ru is the default locale in test, and an
# assertion written as include(I18n.t(key)) cannot fail when the key is
# missing -- it would compare the page against the missing-translation string
# the page also contains.
describe "the operator role in the admin console", type: :request do
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:target)     { create_user }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "offers the grant button for a user without the role" do
    sign_in(superadmin)

    get admin_user_path(target)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(grant_operator_admin_user_path(target))
    expect(response.body).to include("Сделать оператором")
  end

  it "offers the revoke button for a user with the role" do
    target.update!(:is_operator => true)
    sign_in(superadmin)

    get admin_user_path(target)

    expect(response.body).to include(revoke_operator_admin_user_path(target))
    expect(response.body).to include("Снять права оператора")
  end

  it "offers only one of the two at a time" do
    sign_in(superadmin)

    get admin_user_path(target)

    expect(response.body).not_to include(revoke_operator_admin_user_path(target))
  end

  it "tags an operator in the players list" do
    target.update!(:is_operator => true)
    sign_in(superadmin)

    get admin_users_path

    expect(response.body).to include("оператор")
  end

  it "does not tag an ordinary player" do
    target
    sign_in(superadmin)

    get admin_users_path

    expect(response.body).not_to include("оператор")
  end

  # The two roles are independent columns, so both tags can show at once.
  # Scoped to the target's own row: the signed-in superadmin has their own
  # row too, so an unscoped include("администратор") would pass regardless
  # of what the target's row actually shows.
  it "tags a user who holds both roles twice" do
    target.update!(:is_superadmin => true, :is_operator => true)
    sign_in(superadmin)

    get admin_users_path

    doc = Nokogiri::HTML(response.body)
    row = doc.css("tr").find { |tr| tr.at_css("a[href='#{admin_user_path(target)}']") }

    expect(row.text).to include("оператор")
    expect(row.text).to include("администратор")
  end
end
