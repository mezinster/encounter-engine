require "rails_helper"

# Direct coverage for User#last_superadmin?, the predicate that guards
# revocation in Admin::UsersController#revoke.
#
# It has no coverage through the request spec:
# spec/requests/superadmin_granting_spec.rb's "last superadmin" example signs
# in as the last superadmin and has them attempt to revoke themselves, so
# Admin::UsersController#revoke's self-revoke guard (user.id ==
# current_user.id) always fires first -- last_superadmin? is never reached.
# See the comment on that example for the full argument. These examples
# exercise the predicate directly instead.
describe User, "#last_superadmin?" do
  it "is true for a superadmin who is the only one" do
    user = create_user
    user.update!(:is_superadmin => true)

    expect(user.last_superadmin?).to be true
  end

  it "is false for a superadmin when a second superadmin exists" do
    user = create_user
    user.update!(:is_superadmin => true)
    other = create_user
    other.update!(:is_superadmin => true)

    expect(user.last_superadmin?).to be false
  end

  it "is false for a non-superadmin, even when there are no superadmins at all" do
    user = create_user

    expect(User.superadmin_count).to eq(0)
    expect(user.last_superadmin?).to be false
  end
end
