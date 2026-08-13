require "rails_helper"

# The picker reads params directly (it has no model column to read back from
# on a 422), and params carry whatever the URL said. These two shapes were
# unhandled 500s on an author's own edit page -- reachable by mistyping a URL,
# not by attacking anything.
describe "the attachment picker, given a malformed game_file_ids param", :type => :request do
  def login_as(user)
    post login_path, :params => { :email => user.email, :password => "1234" }
  end

  before(:each) do
    @author = create_user
    @game   = create_game(:author => @author)
    @level  = create_level(:game => @game)
    @file   = GameFileUpload.new(@game, fixture_upload("photo.jpg"), @author).call
    @level.replace_attached_files([ @file.id ], nil)
    login_as @author
  end

  it "renders the edit page when game_file_ids arrives as a scalar" do
    # `?level[game_file_ids]=` -- String#reject raised NoMethodError here.
    get edit_game_level_path(@game, @level), :params => { :level => { :game_file_ids => "" } }

    expect(response).to have_http_status(:ok)
  end

  it "renders the edit page when game_file_ids arrives as a nested hash" do
    # `level[game_file_ids][x]=1` -- ActionController::Parameters#reject
    # raised ArgumentError here.
    get edit_game_level_path(@game, @level),
        :params => { :level => { :game_file_ids => { "x" => "1" } } }

    expect(response).to have_http_status(:ok)
  end

  it "falls back to what is actually attached, rather than to nothing" do
    # A malformed shape is not a submission. Falling back to the saved slot is
    # the same answer an ordinary GET gets -- the alternative, treating it as
    # an empty selection, would show the author an unticked picker for files
    # that ARE attached, and their next save would then detach them.
    get edit_game_level_path(@game, @level), :params => { :level => { :game_file_ids => "junk" } }

    checked = Nokogiri::HTML(response.body).at_css("#game_file_#{@file.id}")

    expect(checked&.attr("checked")).to be_present
  end
end
