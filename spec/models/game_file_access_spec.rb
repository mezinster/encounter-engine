require "rails_helper"

describe GameFileAccess do
  before(:each) do
    @author = create_user
    @game   = create_game(:author => @author)
    @file   = GameFileUpload.new(@game, fixture_upload("photo.jpg"), @author).call
  end

  it "permits the game's author" do
    expect(GameFileAccess.new(@author, @file).permitted?).to be true
  end

  it "permits a superadmin who is not the author" do
    admin = create_user
    admin.update_column(:is_superadmin, true)

    expect(GameFileAccess.new(admin, @file).permitted?).to be true
  end

  it "refuses the author of a DIFFERENT game" do
    # Not "some logged-in user" -- an author specifically. authorship is
    # per game, and a policy that checked `user.author_of_anything?` would
    # pass this and hand every author every other author's library.
    other = create_user
    create_game(:author => other)

    expect(GameFileAccess.new(other, @file).permitted?).to be false
  end

  it "refuses an anonymous requester" do
    expect(GameFileAccess.new(nil, @file).permitted?).to be false
  end
end
