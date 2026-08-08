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

  # A stale SHA-1 hash left behind after the bcrypt upgrade is a live
  # credential: authenticate only ignores crypted_password/salt because it
  # checks password_digest.present? first, so anything that ever bypasses
  # that check (a backfill, a restored pre-migration dump, a botched column
  # cleanup) would silently accept the superseded password again. Both
  # columns must go to nil the moment a row is upgraded, not just eventually.
  it "nils crypted_password and salt once a row is upgraded" do
    user = create_user
    legacy_salt = "abc123"
    user.update_columns(:password_digest => nil,
                        :salt => legacy_salt,
                        :crypted_password => User.encrypt("legacypass", legacy_salt))

    user.reload.authenticate("legacypass")

    reloaded = user.reload
    expect(reloaded.crypted_password).to be_nil
    expect(reloaded.salt).to be_nil
  end

  # A subsequent real password change must not leave the SHA-1 of the
  # password it replaced sitting in the legacy columns either -- otherwise
  # nulling password_digest alone (e.g. a careless admin/console action)
  # would silently reauthenticate the *previous* password, not the current
  # one.
  it "keeps crypted_password and salt nil after a later password change" do
    user = create_user
    legacy_salt = "abc123"
    user.update_columns(:password_digest => nil,
                        :salt => legacy_salt,
                        :crypted_password => User.encrypt("legacypass", legacy_salt))
    user.reload.authenticate("legacypass")

    user.reload.update!(:password => "newpass1", :password_confirmation => "newpass1")

    reloaded = user.reload
    expect(reloaded.crypted_password).to be_nil
    expect(reloaded.salt).to be_nil
    expect(BCrypt::Password.new(reloaded.password_digest)).to eq("newpass1")
  end
end
