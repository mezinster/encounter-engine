require "rails_helper"

# None of the controllers these routes point at exist yet (they land in
# later tasks -- see task-7-report.md). RSpec-Rails' `route_to` matcher (and
# even the public `ActionDispatch::Routing::RouteSet#recognize_path` it
# calls) constantizes the target controller and raises
# ActionController::RoutingError when it is missing, in this Rails 8
# version -- so neither can be used here. `recognized_params` goes one layer
# lower, straight to the Journey router that RouteSet#recognize_path itself
# delegates to (see ActionDispatch::Routing::RouteSet#recognize_path_with_request
# in actionpack), which recognizes a path/verb into params without touching
# the controller class at all. That keeps these specs true route-recognition
# tests, not controller-existence tests.
def recognized_params(method:, path:)
  route_set = Rails.application.routes
  route_set.routes # LazyRouteSet only reloads routes from accessors it wraps; `.router` isn't one of them.
  env = Rack::MockRequest.env_for(path, method: method.to_s.upcase)
  request = ActionDispatch::Request.new(env)
  matched = nil
  route_set.router.recognize(request) do |_route, params|
    matched = params
    break
  end
  matched
end

RSpec.describe "routing" do
  def self.it_recognizes(description, method:, path:, to:)
    it description do
      expect(recognized_params(method: method, path: path)).to eq(to)
    end
  end

  it_recognizes "keeps GET /play/:game_id",
    method: :get, path: "/play/7",
    to: { controller: "game_passings", action: "show_current_level", game_id: "7" }

  it_recognizes "keeps POST /play/:game_id",
    method: :post, path: "/play/7",
    to: { controller: "game_passings", action: "post_answer", game_id: "7" }

  it_recognizes "keeps GET /play/:game_id/tip",
    method: :get, path: "/play/7/tip",
    to: { controller: "game_passings", action: "get_current_level_tip", game_id: "7" }

  it_recognizes "keeps the nested authoring routes",
    method: :get, path: "/games/3/levels/9/hints",
    to: { controller: "hints", action: "index", game_id: "3", level_id: "9" }

  it_recognizes "keeps /stats/show_results/:game_id",
    method: :get, path: "/stats/show_results/7",
    to: { controller: "game_passings", action: "show_results", game_id: "7" }

  it_recognizes "keeps /stats/index/:game_id",
    method: :get, path: "/stats/index/7",
    to: { controller: "game_passings", action: "index", game_id: "7" }

  # These two used to route. `/stats/:action/:game_id` mapped EVERY action on
  # GamePassingsController, so a state-changing action was reachable over GET
  # with no CSRF token -- a captain who followed a crafted link, or whose
  # browser prefetched one, quit their team out of a live game. The pair of
  # static routes that replaced it is what closes that, and this is the
  # assertion that would notice a dynamic segment creeping back.
  [ "exit_game", "post_answer", "get_current_level_tip", "set_content_locale" ].each do |action|
    it "does not expose game_passings##{action} over GET /stats" do
      expect(recognized_params(:method => :get, :path => "/stats/#{action}/7")).to be_nil
    end
  end

  it_recognizes "keeps /logs/livechannel/:game_id",
    method: :get, path: "/logs/livechannel/7",
    to: { controller: "logs", action: "show_live_channel", game_id: "7" }

  it_recognizes "keeps /logs/level/:game_id/:team_id",
    method: :get, path: "/logs/level/7/2",
    to: { controller: "logs", action: "show_level_log", game_id: "7", team_id: "2" }

  it_recognizes "keeps /logs/game/:game_id/:team_id",
    method: :get, path: "/logs/game/7/2",
    to: { controller: "logs", action: "show_game_log", game_id: "7", team_id: "2" }

  it_recognizes "keeps /logs/full/:game_id",
    method: :get, path: "/logs/full/7",
    to: { controller: "logs", action: "show_full_log", game_id: "7" }

  it_recognizes "keeps the root URL",
    method: :get, path: "/",
    to: { controller: "index", action: "index" }

  it_recognizes "keeps /dashboard",
    method: :get, path: "/dashboard",
    to: { controller: "dashboard", action: "index" }

  it_recognizes "keeps /team-room",
    method: :get, path: "/team-room",
    to: { controller: "team_room", action: "index" }

  it_recognizes "keeps GET /login",
    method: :get, path: "/login",
    to: { controller: "sessions", action: "new" }

  it_recognizes "keeps POST /login",
    method: :post, path: "/login",
    to: { controller: "sessions", action: "create" }

  it_recognizes "keeps PUT /login (merb-auth's login form posted _method=PUT)",
    method: :put, path: "/login",
    to: { controller: "sessions", action: "create" }

  it_recognizes "keeps GET /logout (the existing plain link and Cucumber's raw GET visits rely on this)",
    method: :get, path: "/logout",
    to: { controller: "sessions", action: "destroy" }

  it_recognizes "keeps DELETE /logout (the Rails-idiomatic form)",
    method: :delete, path: "/logout",
    to: { controller: "sessions", action: "destroy" }

  it_recognizes "keeps /signup",
    method: :get, path: "/signup",
    to: { controller: "users", action: "new" }

  it_recognizes "keeps the nested /users/:user_id/games used by GamesController#index",
    method: :get, path: "/users/4/games",
    to: { controller: "games", action: "index", user_id: "4" }

  it_recognizes "keeps /games/start_test/:id",
    method: :post, path: "/games/start_test/7",
    to: { controller: "games", action: "start_test", id: "7" }

  it_recognizes "keeps /games/finish_test/:id",
    method: :post, path: "/games/finish_test/7",
    to: { controller: "games", action: "finish_test", id: "7" }

  it_recognizes "keeps /games/end_game/:id",
    method: :post, path: "/games/end_game/7",
    to: { controller: "games", action: "end_game", id: "7" }

  it_recognizes "keeps /game_passings/exit_game/:game_id",
    method: :get, path: "/game_passings/exit_game/7",
    to: { controller: "game_passings", action: "exit_game", game_id: "7" }

  it_recognizes "keeps /game_passings/show_results (Merb's :default route for a Hash url(), game_id arrives via query string)",
    method: :get, path: "/game_passings/show_results",
    to: { controller: "game_passings", action: "show_results" }

  it_recognizes "keeps /games/:id/delete (Merb resources' auto member :delete)",
    method: :delete, path: "/games/7/delete",
    to: { controller: "games", action: "delete", id: "7" }

  it_recognizes "keeps /games/:game_id/levels/:id/delete",
    method: :delete, path: "/games/7/levels/9/delete",
    to: { controller: "levels", action: "delete", game_id: "7", id: "9" }

  it_recognizes "keeps /games/:game_id/levels/:id/move_up",
    method: :post, path: "/games/7/levels/9/move_up",
    to: { controller: "levels", action: "move_up", game_id: "7", id: "9" }

  it_recognizes "keeps /games/:game_id/levels/:id/move_down",
    method: :post, path: "/games/7/levels/9/move_down",
    to: { controller: "levels", action: "move_down", game_id: "7", id: "9" }

  it_recognizes "keeps /games/:game_id/levels/:level_id/hints/:id/delete",
    method: :delete, path: "/games/7/levels/9/hints/3/delete",
    to: { controller: "hints", action: "delete", game_id: "7", level_id: "9", id: "3" }

  it_recognizes "keeps /games/:game_id/levels/:level_id/questions/:question_id/answers/:id/delete",
    method: :delete, path: "/games/7/levels/9/questions/2/answers/1/delete",
    to: { controller: "answers", action: "delete", game_id: "7", level_id: "9", question_id: "2", id: "1" }

  it_recognizes "keeps /invitations/accept/:id",
    method: :get, path: "/invitations/accept/5",
    to: { controller: "invitations", action: "accept", id: "5" }

  it_recognizes "keeps /invitations/reject/:id",
    method: :get, path: "/invitations/reject/5",
    to: { controller: "invitations", action: "reject", id: "5" }

  it_recognizes "keeps /game_entries/new/:game_id/:team_id",
    method: :get, path: "/game_entries/new/7/2",
    to: { controller: "game_entries", action: "new", game_id: "7", team_id: "2" }

  it_recognizes "keeps /game_entries/reopen/:id",
    method: :get, path: "/game_entries/reopen/5",
    to: { controller: "game_entries", action: "reopen", id: "5" }

  it_recognizes "keeps /game_entries/accept/:id",
    method: :get, path: "/game_entries/accept/5",
    to: { controller: "game_entries", action: "accept", id: "5" }

  it_recognizes "keeps /game_entries/reject/:id",
    method: :get, path: "/game_entries/reject/5",
    to: { controller: "game_entries", action: "reject", id: "5" }

  it_recognizes "keeps /game_entries/recall/:id",
    method: :get, path: "/game_entries/recall/5",
    to: { controller: "game_entries", action: "recall", id: "5" }

  it_recognizes "keeps /game_entries/cancel/:id",
    method: :get, path: "/game_entries/cancel/5",
    to: { controller: "game_entries", action: "cancel", id: "5" }

  # Negative checks: prove the router is not over-permissive. A route file
  # that matched everything would pass every `it_recognizes` example above
  # too, so these guard against that.
  it "does not recognize /play/:game_id for an unexpected verb" do
    expect(recognized_params(method: :delete, path: "/play/7")).to be_nil
    expect(recognized_params(method: :put, path: "/play/7")).to be_nil
  end

  it "does not recognize a nonsense path" do
    expect(recognized_params(method: :get, path: "/this/does/not/exist/anywhere")).to be_nil
  end

  it "does not recognize /logout for verbs we did not intentionally add (only GET and DELETE are wired up)" do
    expect(recognized_params(method: :put, path: "/logout")).to be_nil
    expect(recognized_params(method: :post, path: "/logout")).to be_nil
  end
end
