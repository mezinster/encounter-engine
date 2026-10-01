require "rails_helper"

# The invitation page offers every other user's nickname through a native
# <datalist>. Nicknames only -- emails were removed from this page as a
# security fix (any captain can open it, and captaincy is self-service).
describe "the invitation nickname list", type: :request do
  let(:captain) { create_user }
  let!(:other)  { create_user }
  let(:doc)     { Nokogiri::HTML(response.body) }

  before do
    create_team(:captain => captain)
    put login_path, :params => { :email => captain.email, :password => "1234" }
  end

  it "links the nickname field to a datalist of the other users" do
    get new_invitation_path

    field = doc.at_css("input#invitation_recepient_nickname")
    expect(field["list"]).to eq("invitation-nicknames")
    values = doc.css("datalist#invitation-nicknames option").map { |o| o["value"] }
    expect(values).to include(other.nickname)
    expect(values).not_to include(captain.nickname)
  end

  it "exposes no user's e-mail address" do
    get new_invitation_path

    User.find_each { |u| expect(response.body).not_to include(u.email) }
  end

  it "renders a hostile nickname as inert text" do
    other.update!(:nickname => %q{x" onmouseover="alert(1)</datalist><b>})
    get new_invitation_path

    expect(doc.css("datalist#invitation-nicknames option").map { |o| o["value"] }).to include(other.nickname)
    expect(doc.at_css("b")).to be_nil
    expect(doc.css("[onmouseover]")).to be_empty
  end

  it "renders a tag-closing nickname as inert text" do
    other.update!(:nickname => %q{x"></option></datalist><b>bold})
    get new_invitation_path

    expect(doc.css("datalist#invitation-nicknames option").map { |o| o["value"] }).to include(other.nickname)
    expect(doc.at_css("b")).to be_nil
  end

  # Carried over from the retired invitations_autocomplete_spec.rb: a nickname
  # ending in a backslash once escaped the closing quote of a JS string literal
  # and put the next value in executable position. In an attribute there is no
  # string literal to escape, and the value must survive byte for byte.
  it "keeps a backslash nickname literal" do
    other.update!(:nickname => "evil\\")
    get new_invitation_path

    expect(doc.css("datalist#invitation-nicknames option").map { |o| o["value"] }).to include("evil\\")
  end

  it "loads no jQuery or autocomplete plugin" do
    get new_invitation_path

    expect(response.body).not_to match(/jquery(\.autocomplete)?\.(js|css)/)
    expect(doc.css("script[type='application/json']")).to be_empty
    # No inline script either: that is the JS context the backslash bug lived in.
    expect(doc.css("script:not([src])")).to be_empty
  end
end
