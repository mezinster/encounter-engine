Rails.application.routes.draw do
  # kamal-proxy polls this during deploys and will not cut traffic over to a
  # container that does not answer it. Rails ships the controller; this app's
  # routes were ported from Merb, so the route was never added.
  get "up" => "rails/health#show", as: :rails_health_check

  root to: "index#index"

  # The superadmin console: a read-only listing of every game on the
  # instance. Editing rides the author's own forms (ensure_author admits
  # superadmins), so only :index exists here -- there is no second editor.
  namespace :admin do
    get "/", to: "dashboard#show", as: :dashboard
    resources :games, only: [ :index ]
    resources :users, only: [ :index, :show ] do
      post "grant",  on: :member
      post "revoke", on: :member
    end
    resources :audit, only: [ :index ]
  end

  # Session/registration URLs replace merb-auth's merb_auth_slice_password
  # slice (formerly vendor/merb-auth/merb-auth-slice-password, removed by
  # Task 13 -- see git history before this port's commits), which served:
  #   GET  /login   -> exceptions#unauthenticated (renders the login form)
  #   PUT  /login   -> sessions#update            (performs the login)
  #   *    /logout  -> sessions#destroy           (no :method restriction --
  #                    matched ANY verb)
  # The controllers are redesigned in a later task with standard Rails verbs
  # (new/create/destroy), but /logout must keep responding to GET: the
  # existing "Выйти" link (app/views/layouts/_left_menu.html.erb) is a plain
  # <a href="/logout">, and features/authentication/logout.feature drives it
  # with a raw GET ("захожу по адресу /logout" -> Capybara #visit). DELETE is
  # added too, for whenever the view is updated to a Rails-idiomatic
  # button_to/link_to method: :delete.
  get    "/login",  to: "sessions#new",     as: :login
  post   "/login",  to: "sessions#create"
  # merb-auth's login form posted a hidden _method=PUT
  # (merb-auth-slice-password/app/views/exceptions/unauthenticated.html.erb:9-10,
  # removed by Task 13 -- see git history)
  # against the PUT /login route (…lib/merb-auth-slice-password.rb:65). Keep
  # PUT accepted alongside POST so that verb is still served, even though
  # Task 6/9 own the actual form markup going forward.
  put    "/login",  to: "sessions#create"
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

  # Merb's `resources` auto-added `GET /<resource>/:id/edit` AND
  # `GET /<resource>/:id/delete` to every `resources` call by default
  # (merb-core/lib/merb-core/dispatch/router/resources.rb:80, removed by
  # Task 13 -- see git history -- `member = { :edit => :get, :delete => :get }`).
  # Rails' `resources` only
  # adds :edit. None of these controllers define a `destroy` action (Rails'
  # convention) -- they define `delete` (a GET-rendered confirmation page,
  # per app/controllers/games.rb:55, levels.rb:37, hints.rb:35,
  # answers.rb:23), and every deletion link in app/views calls that
  # `/.../:id/delete` path via `resource(..., :delete)`. Restore the member
  # route for the four resources actually linked that way.
  resources :games do
    member do
      get :delete
      post :withdraw
      post :restore
      post :lock
      post :unlock
    end

    resources :levels do
      member do
        get :delete
        get :move_up
        get :move_down
      end

      resources :hints do
        member do
          get :delete
        end
      end

      resources :questions do
        resources :answers do
          member do
            get :delete
          end
        end
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

  # app/views/dashboard/_finished_games.html.erb:7 and
  # app/views/shared/_current_games.html.erb:13 build this URL with
  # `url(:controller => :game_passings, :action => :show_results, :game_id
  # => game.id)` -- a Hash argument, which Merb resolves through the
  # `:default` route (merb-core/lib/merb-core/dispatch/router.rb:221-232,
  # i.e. default_routes' `/:controller(/:action(/:id))`; removed by Task 13,
  # see git history), NOT
  # through the named `game_stats` route below. The generated URL is
  # `/game_passings/show_results?game_id=7` (leftover params become a query
  # string), not `/stats/show_results/7`. game_id arrives via the query
  # string, so it isn't declared as a path segment here.
  get "/game_passings/show_results", to: "game_passings#show_results"

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
  post "/play/:game_id/content_locale", to: "game_passings#set_content_locale", as: :set_content_locale

  get "/stats/:action/:game_id", controller: "game_passings", as: :game_stats
  get "/logs/livechannel/:game_id",     to: "logs#show_live_channel", as: :show_live_channel # прямой эфир
  get "/logs/level/:game_id/:team_id",  to: "logs#show_level_log",    as: :show_level_log    # лог по уровню
  get "/logs/game/:game_id/:team_id",   to: "logs#show_game_log",     as: :show_game_log     # лог по игре
  get "/logs/full/:game_id",            to: "logs#show_full_log",     as: :show_full_log     # полный лог по игре
end
