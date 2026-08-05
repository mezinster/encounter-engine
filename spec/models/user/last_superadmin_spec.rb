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

# The model-level validation that actually closes the last-superadmin gap.
# Admin::UsersController#revoke's own guard can never be reached (see the
# comment above and on the request spec), so the real risk is a console
# mistake -- `u.update!(:is_superadmin => false)` on the only administrator --
# which this validation exists to stop.
describe User, "#last_superadmin_keeps_the_role validation" do
  it "rejects clearing is_superadmin on the only superadmin" do
    user = create_user
    user.update!(:is_superadmin => true)

    expect(user.update(:is_superadmin => false)).to be false
    expect(user.errors[:is_superadmin]).to be_present

    expect(user.reload.superadmin?).to be true
  end

  it "allows clearing is_superadmin when a second superadmin exists" do
    user = create_user
    user.update!(:is_superadmin => true)
    other = create_user
    other.update!(:is_superadmin => true)

    expect(user.update(:is_superadmin => false)).to be true
    expect(user.reload.superadmin?).to be false
  end

  # No ActiveRecord validation can stop raw SQL, and
  # spec/requests/superadmin_granting_spec.rb's last-superadmin example
  # deliberately relies on this bypass to arrange its "exactly one
  # superadmin, signed in as them" setup. Don't try to make this airtight --
  # there's nothing in Rails that would let you, and doing so would break
  # that spec's setup.
  it "does not stop update_column from clearing the flag directly" do
    user = create_user
    user.update!(:is_superadmin => true)

    user.update_column(:is_superadmin, false)

    expect(user.reload.superadmin?).to be false
  end

  it "does not fire on unrelated saves" do
    user = create_user

    expect(user.update(:is_superadmin => true)).to be true

    user.update!(:is_superadmin => true)
    expect(user.update(:nickname => user.nickname + "2")).to be true
  end
end
