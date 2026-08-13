require "rails_helper"

describe "file delivery", :type => :request do
  # Defined here, not shared: Phase 2B's spec/requests/game_files_spec.rb
  # defines its own copy at line 4 and there is no shared request-spec login
  # helper in spec/spec_helpers/. Copy this shape verbatim -- create_user
  # generates the password "1234", which is what makes this work.
  def login_as(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  before(:each) do
    @author = create_user
    @game   = create_game(:author => @author)
    @file   = GameFileUpload.new(@game, fixture_upload("photo.jpg"), @author).call
  end

  def deliver(variant = "original")
    get game_file_delivery_path(@game, @file, variant)
  end

  it "serves the original to the game's author" do
    login_as @author
    deliver

    expect(response).to have_http_status(:ok)
    expect(response.body.bytesize).to eq(@file.byte_size)
  end

  it "404s for a logged-out requester" do
    deliver
    expect(response).to have_http_status(:not_found)
  end

  it "404s for a signed-in user with no connection to the game" do
    # 404, NOT 403: a 403 confirms the file exists, which tells an attacker
    # enumerating ids exactly which ones are real.
    login_as create_user
    deliver

    expect(response).to have_http_status(:not_found)
  end

  it "404s for a file id belonging to a different game" do
    other_game = create_game(:author => @author)
    other_file = GameFileUpload.new(other_game, fixture_upload("map.pdf"), @author).call

    login_as @author
    get game_file_delivery_path(@game, other_file, "original")

    expect(response).to have_http_status(:not_found)
  end

  it "never routes a variant name outside the whitelist" do
    # The route's own :constraints regex (config/routes.rb) is anchored to the
    # whole :variant segment -- confirmed via
    # Rails.application.routes.recognize_path, which raises RoutingError for
    # a single bad segment like "nope". So this can never reach
    # FileDeliveriesController#show at all: config.action_dispatch.show_exceptions
    # is :none in the test environment (config/environments/test.rb), so an
    # unmatched route raises here rather than rendering a 404 response -- there
    # is no HTTP-level response to assert :not_found against, only a routing
    # failure. This also means an HTTP request can never exercise the
    # controller's OWN VARIANTS.include? check as long as it lists the same
    # three values as this constraint (see the "load-bearing whitelist" note
    # in the task report for what was tried and why it could not be done with
    # this app's existing test infrastructure).
    login_as @author

    expect {
      get "/games/#{@game.id}/files/#{@file.id}/nope"
    }.to raise_error(ActionController::RoutingError)
  end

  it "never routes a path-traversal attempt through the :variant segment" do
    # Blocked for a different reason than the case above: this string
    # decomposes into five path segments ("..", "..", "..", "etc", "passwd"),
    # and the route only ever captures one segment for :variant -- so this
    # never matches regardless of what the :variant constraint allows. Kept as
    # a separate example because it is the concrete attack a whitelist on this
    # route exists to stop, even though it happens to fail one layer earlier.
    login_as @author

    expect {
      get "/games/#{@game.id}/files/#{@file.id}/../../../etc/passwd"
    }.to raise_error(ActionController::RoutingError)
  end
end
