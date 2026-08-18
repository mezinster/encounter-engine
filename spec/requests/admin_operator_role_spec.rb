require "rails_helper"

describe "granting and revoking the operator role", type: :request do
  let(:ordinary)   { create_user }
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:target)     { create_user }

  # config/routes.rb maps GET /login to sessions#new (the form) and PUT /login
  # to sessions#update. It is PUT, not POST. create_user sets the password to
  # "1234".
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "refuses an anonymous visitor" do
    post grant_operator_admin_user_path(target)

    expect(response).to have_http_status(:found)
    expect(response).to redirect_to(login_path)
    expect(target.reload.operator?).to be false
  end

  it "refuses an ordinary signed-in user" do
    sign_in(ordinary)

    post grant_operator_admin_user_path(target)

    expect(response).to have_http_status(:unauthorized)
    expect(target.reload.operator?).to be false
  end

  # D7: the role does not open the console. An operator cannot make more
  # operators; only a superadmin can.
  it "refuses an operator who is not a superadmin" do
    operator = create_user
    operator.update!(:is_operator => true)
    sign_in(operator)

    post grant_operator_admin_user_path(target)

    expect(response).to have_http_status(:unauthorized)
    expect(target.reload.operator?).to be false
  end

  it "grants the role for a superadmin" do
    sign_in(superadmin)

    post grant_operator_admin_user_path(target)

    expect(response).to redirect_to(admin_user_path(target))
    expect(target.reload.operator?).to be true
  end

  it "revokes the role for a superadmin" do
    target.update!(:is_operator => true)
    sign_in(superadmin)

    post revoke_operator_admin_user_path(target)

    expect(response).to redirect_to(admin_user_path(target))
    expect(target.reload.operator?).to be false
  end

  # D4: no last-holder guard and no self guard, unlike #revoke. Both of that
  # method's guards protect against locking the instance out of
  # administration; a superadmin can always grant the operator role back.
  it "lets a superadmin revoke the operator role from themselves" do
    superadmin.update!(:is_operator => true)
    sign_in(superadmin)

    post revoke_operator_admin_user_path(superadmin)

    expect(response).to redirect_to(admin_user_path(superadmin))
    expect(superadmin.reload.operator?).to be false
  end

  it "lets a superadmin revoke the operator role from the only operator" do
    target.update!(:is_operator => true)
    sign_in(superadmin)

    post revoke_operator_admin_user_path(target)

    expect(target.reload.operator?).to be false
  end

  it "leaves is_superadmin untouched when granting the operator role" do
    sign_in(superadmin)

    post grant_operator_admin_user_path(target)

    expect(target.reload.is_superadmin).to be false
  end
end
