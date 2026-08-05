require "rails_helper"

describe User do
  it "is not a superadmin by default" do
    expect(create_user.superadmin?).to be false
  end

  it "is a superadmin when the flag is set" do
    user = create_user
    user.update!(:is_superadmin => true)
    expect(user.reload.superadmin?).to be true
  end
end
