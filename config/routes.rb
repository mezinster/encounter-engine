Rails.application.routes.draw do
  root to: "index#index"

  # Session/registration URLs replace merb-auth's merb_auth_slice_password
  # slice (vendor/merb-auth/merb-auth-slice-password), which served:
  #   GET  /login   -> exceptions#unauthenticated (renders the login form)
  #   PUT  /login   -> sessions#update            (performs the login)
  #   *    /logout  -> sessions#destroy           (no :method restriction --
  #                    matched ANY verb)
  # The controllers are redesigned in a later task with standard Rails verbs
  # (new/create/destroy), but /logout must keep responding to GET: the
  # existing "Выйти" link (app/views/layout/_left_menu.html.erb) is a plain
  # <a href="/logout">, and features/authentication/logout.feature drives it
  # with a raw GET ("захожу по адресу /logout" -> Capybara #visit). DELETE is
  # added too, for whenever the view is updated to a Rails-idiomatic
  # button_to/link_to method: :delete.
  get    "/login",  to: "sessions#new",     as: :login
  post   "/login",  to: "sessions#create"
  get    "/logout", to: "sessions#destroy", as: nil
  delete "/logout", to: "sessions#destroy", as: :logout
  get    "/signup", to: "users#new",        as: :signup

  get "/dashboard", to: "dashboard#index", as: :dashboard
  get "/team-room", to: "team_room#index", as: :team_room

  # Merb's router nested :games under :users (`resources :users do
  # resources :games end`), because GamesController#index optionally scopes
  # by params[:user_id] (see app/controllers/games.rb). Keep the nesting so
  # /users/:user_id/games keeps resolving, in addition to the flat /users
  # routes.
  resources :users do
    resources :games
  end
  resources :teams
  resources :invitations

  resources :games do
    resources :levels do
      resources :hints
      resources :questions do
        resources :answers
      end

      member do
        get :move_up
        get :move_down
      end
    end
  end

  # The routes below have no `resources` equivalent: in Merb they were only
  # reachable through the catch-all `default_routes` entry
  # (`match("/:controller(/:action(/:id))(.:format)")`) at the bottom of
  # config/router.rb, which Rails has no equivalent of. Every path here is
  # exercised today via a plain (GET) link_to in app/views -- see the grep
  # evidence in task-7-report.md -- so each is added as a `get` route in the
  # same /:controller/:action/:id segment order Merb used (action before id).
  get "/games/start_test/:id",  to: "games#start_test"
  get "/games/finish_test/:id", to: "games#finish_test"
  get "/games/end_game/:id",    to: "games#end_game"

  get "/game_passings/exit_game/:game_id", to: "game_passings#exit_game", as: :exit_game

  get "/invitations/accept/:id", to: "invitations#accept"
  get "/invitations/reject/:id", to: "invitations#reject"

  get "/game_entries/new/:game_id/:team_id", to: "game_entries#new", as: :new_game_entry
  get "/game_entries/reopen/:id", to: "game_entries#reopen"
  get "/game_entries/accept/:id", to: "game_entries#accept"
  get "/game_entries/reject/:id", to: "game_entries#reject"
  get "/game_entries/recall/:id", to: "game_entries#recall"
  get "/game_entries/cancel/:id", to: "game_entries#cancel"

  # Gameplay paths are load-bearing: they appear in features and in links
  # players have bookmarked. Keep them exactly as Merb served them.
  get  "/play/:game_id/tip", to: "game_passings#get_current_level_tip", as: :get_current_level_tip
  get  "/play/:game_id",     to: "game_passings#show_current_level",    as: :show_current_level
  post "/play/:game_id",     to: "game_passings#post_answer",           as: :post_answer

  get "/stats/:action/:game_id", controller: "game_passings", as: :game_stats
  get "/logs/livechannel/:game_id",     to: "logs#show_live_channel", as: :show_live_channel # прямой эфир
  get "/logs/level/:game_id/:team_id",  to: "logs#show_level_log",    as: :show_level_log    # лог по уровню
  get "/logs/game/:game_id/:team_id",   to: "logs#show_game_log",     as: :show_game_log     # лог по игре
  get "/logs/full/:game_id",            to: "logs#show_full_log",     as: :show_full_log     # полный лог по игре
end
