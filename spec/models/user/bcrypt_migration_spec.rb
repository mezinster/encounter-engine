require "rails_helper"

describe User, "password hashing" do
  it "stores new passwords as bcrypt" do
    user = create_user

    expect(user.password_digest).to be_present
    expect(BCrypt::Password.new(user.password_digest)).to eq("1234")
  end

  it "still verifies a legacy SHA-1 row" do
    user = create_user
    legacy_salt = "abc123"
    user.update_columns(:password_digest => nil,
                        :salt => legacy_salt,
                        :crypted_password => User.encrypt("legacypass", legacy_salt))

    expect(user.reload.authenticate("legacypass")).to be true
    expect(user.authenticate("wrong")).to be false
  end

  it "upgrades a legacy row on successful authentication" do
    user = create_user
    legacy_salt = "abc123"
    user.update_columns(:password_digest => nil,
                        :salt => legacy_salt,
                        :crypted_password => User.encrypt("legacypass", legacy_salt))

    user.reload.authenticate("legacypass")

    expect(user.reload.password_digest).to be_present
    expect(BCrypt::Password.new(user.password_digest)).to eq("legacypass")
  end

  it "does not upgrade on a failed authentication" do
    user = create_user
    legacy_salt = "abc123"
    user.update_columns(:password_digest => nil,
                        :salt => legacy_salt,
                        :crypted_password => User.encrypt("legacypass", legacy_salt))

    user.reload.authenticate("wrong")

    expect(user.reload.password_digest).to be_nil
  end
end
