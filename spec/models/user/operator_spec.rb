require "rails_helper"

describe User do
  it "is not an operator by default" do
    expect(create_user.operator?).to be false
  end

  it "is an operator when the flag is set" do
    user = create_user
    user.update!(:is_operator => true)
    expect(user.reload.operator?).to be true
  end

  # D3: the two columns are independent. Granting superadmin must not set
  # is_operator, or revoking the operator role from a superadmin would appear
  # to work, change nothing observable, and leave the row disagreeing with the
  # screen.
  it "does not become an operator when granted superadmin" do
    user = create_user
    user.update!(:is_superadmin => true)
    expect(user.reload.operator?).to be false
  end

  describe "#may_operate_commercial?" do
    it "is false for an ordinary user" do
      expect(create_user.may_operate_commercial?).to be false
    end

    it "is true for an operator who is not a superadmin" do
      user = create_user
      user.update!(:is_operator => true)
      expect(user.reload.may_operate_commercial?).to be true
    end

    it "is true for a superadmin who does not hold the operator role" do
      user = create_user
      user.update!(:is_superadmin => true)
      expect(user.reload.may_operate_commercial?).to be true
    end
  end
end
