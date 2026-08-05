require "rails_helper"

describe "granting the superadmin role", type: :request do
  let(:ordinary)   { create_user }
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "refuses an ordinary signed-in user" do
    target = create_user
    sign_in(ordinary)
    post grant_admin_user_path(target)
    expect(response).to have_http_status(:unauthorized)
    expect(target.reload.superadmin?).to be false
  end

  it "lets a superadmin grant the role, and records it" do
    target = create_user
    sign_in(superadmin)

    expect { post grant_admin_user_path(target) }.to change { AdminAction.count }.by(1)

    expect(target.reload.superadmin?).to be true
    entry = AdminAction.newest_first.first
    expect(entry.action).to eq("grant_superadmin")
    expect(entry.target_label).to eq(target.nickname)
  end

  it "lets a superadmin revoke someone else's role, and records it" do
    other = create_user
    other.update!(:is_superadmin => true)
    sign_in(superadmin)

    expect { post revoke_admin_user_path(other) }.to change { AdminAction.count }.by(1)

    expect(other.reload.superadmin?).to be false
    expect(AdminAction.newest_first.first.action).to eq("revoke_superadmin")
  end

  # Prevents the accidental self-lockout, and means every demotion has a
  # second party recorded in the log.
  it "refuses to let a superadmin revoke their own role" do
    other = create_user
    other.update!(:is_superadmin => true)
    sign_in(superadmin)

    expect { post revoke_admin_user_path(superadmin) }.not_to change { AdminAction.count }
    expect(superadmin.reload.superadmin?).to be true
  end

  # The instance must never reach a state where nobody can administer it.
  it "refuses to revoke the last superadmin" do
    sign_in(superadmin)
    only = create_user
    only.update!(:is_superadmin => true)
    superadmin.update_column(:is_superadmin, false)
    sign_in(only)

    expect(User.superadmin_count).to eq(1)
    expect { post revoke_admin_user_path(only) }.not_to change { AdminAction.count }
    expect(only.reload.superadmin?).to be true
  end
end
