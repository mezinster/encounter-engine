require "rails_helper"

describe User, "find_by_reset_token" do
  let(:user) { create_user }

  it "returns nil for a blank token, rather than matching a row with a nil digest" do
    # Every freshly created user has reset_password_token_digest = nil (no
    # reset ever issued). A nil/blank raw token must not resolve to one of
    # those rows -- e.g. via digest_reset_token(nil) coincidentally matching
    # a NULL column, or a naive `where(digest: nil)` scope.
    user
    expect(user.reset_password_token_digest).to be_nil

    expect(User.find_by_reset_token(nil)).to be_nil
    expect(User.find_by_reset_token("")).to be_nil
  end

  it "finds the user for a freshly issued token" do
    raw = user.issue_reset_password_token!
    expect(User.find_by_reset_token(raw)).to eq(user)
  end

  it "does not match a wrong token even while a valid one exists" do
    user.issue_reset_password_token!
    expect(User.find_by_reset_token("not-the-real-token")).to be_nil
  end
end
