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
    # Operator-tunable rate limits. GET shows the form, PATCH saves it.
    get   "/settings", to: "settings#show",   as: :settings
    patch "/settings", to: "settings#update"
    # The console is otherwise read-only -- editing rides the author's own
    # forms. Authorship is the exception: there is no author's form an operator
    # can borrow when the point is that the current author cannot or will not
    # act. Mirrors admin teams' set_captain.
    resources :games, only: [ :index ] do
      post "set_author", on: :member
      post "open_run",   on: :member

      # Nested under the game deliberately: free_place_of_team! is a method on
      # Game, and the redirect target is this screen, so both need the game in
      # scope regardless.
      resources :entries, only: [ :index ], controller: "game_entries" do
        member do
          post :accept
          post :reject
        end
      end
    end
    resources :teams, only: [ :index ] do
      post "set_captain", on: :member
      delete "destroy", on: :member, as: :destroy
    end
    resources :users, only: [ :index, :show ] do
      post "grant",  on: :member
      post "revoke", on: :member
      # The operator role. Separate actions rather than a parameterised one:
      # grant/revoke above are superadmin's and have guards these must not
      # inherit -- see the operator-role design, D4.
      post "grant_operator",  on: :member
      post "revoke_operator", on: :member
      post "move",   on: :member
      delete "destroy", on: :member, as: :destroy
      post "anonymise", on: :member
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

  get   "/password/new",  to: "password_resets#new",    as: :new_password_reset
  post  "/password",      to: "password_resets#create", as: :password_resets
  get   "/password/edit", to: "password_resets#edit",   as: :edit_password_reset
  patch "/password",      to: "password_resets#update", as: :password_reset

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
  # The bare resource also generates index/show/edit/update/destroy routes
  # with no actions behind them; those 404 via ActionNotFound before any
  # filter. That is pre-existing and deliberately left alone -- only the
  # member route below is added.
  resources :teams do
    post "hand_over", on: :member
    # Collection, not member: the team is derived from current_user, so there
    # is no id here to forge.
    post "leave", on: :collection
  end
  # Applying to join a team. Separate controller from deciding, because the
  # two halves have different actors and therefore different guards.
  post "/teams/:team_id/join_requests", to: "team_join_requests#create",
                                        as: :team_join_requests
  post "/join_requests/:id/accept", to: "team_join_decisions#accept", as: :accept_join_request
  post "/join_requests/:id/reject", to: "team_join_decisions#reject", as: :reject_join_request
  resources :invitations

  # Merb's `resources` auto-added `GET /<resource>/:id/edit` AND
  # `GET /<resource>/:id/delete` to every `resources` call by default
  # (merb-core/lib/merb-core/dispatch/router/resources.rb:80, removed by
  # Task 13 -- see git history -- `member = { :edit => :get, :delete => :get }`).
  # Rails' `resources` only adds :edit.
  #
  # These controllers define `delete`, not Rails' conventional `destroy`, and
  # the action name is kept -- but the VERB is DELETE, not GET. Every one of
  # these actions destroys immediately; none renders a confirmation page (an
  # earlier version of this comment claimed otherwise, which was wrong about
  # both this code and the Merb original). Rails skips CSRF verification for
  # GET by design, so a destructive action on GET is a destructive action with
  # no CSRF protection. The views drive these with button_to; this app has no
  # Turbo and no rails-ujs, so link_to with :method does nothing here.
  resources :games do
    member do
      delete :delete
      post :withdraw
      post :restore
      post :unfinish
      post :lock
      post :unlock

      # Handing the game to another player. POST, not GET: this app has no
      # Turbo and no rails-ujs, so the view drives it with a real form.
      post :hand_over

      # Which language this reader sees the game's authored content in.
      # POST because it writes; a member route because the preference is
      # per-game. The play screen keeps its own route (set_content_locale_path,
      # under /play) -- same write, different guards and redirect.
      post :set_content_locale
    end

    # Singular: a game has one import screen, not a collection of imports.
    # Nothing is persisted for the import itself -- the pasted text rides a
    # hidden field between preview and confirm.
    resource :quiz_import, only: [ :new, :create ]

    # The per-game file library. No :show -- a file is served by phase 3's
    # delivery route, which authorises per level/hint rather than per game.
    resources :game_files, :only => [ :index, :create, :destroy ]

    # Phase 3's delivery route. Deliberately NOT `resources :game_files, :only
    # => [:show]`: that controller is author-only, and this path must admit
    # playing teams. :variant never becomes a path component -- the matched
    # value only ever selects a METHOD in the controller.
    #
    # The :constraints regex below is the control that actually runs: it
    # rejects an out-of-whitelist :variant before routing even reaches
    # FileDeliveriesController, which is why the controller's own
    # FileDeliveriesController::VARIANTS.include? check can never be
    # exercised by an HTTP request as long as the two lists agree (see the
    # comment on VARIANTS there). Both are kept: this regex is the one
    # request-facing guard; the controller's array is defence-in-depth against
    # the two ever drifting apart, e.g. if this regex is loosened without the
    # array changing to match -- guarded by a spec asserting they stay equal.
    get "files/:id/:variant", :to => "file_deliveries#show", :as => :file_delivery,
                              :constraints => { :variant => /original|web|thumb/ }

    resources :levels do
      member do
        delete :delete
        post :move_up
        post :move_down
      end

      resources :hints do
        member do
          delete :delete
        end
      end

      resources :questions do
        # Deleting a code, mirroring the DELETE :delete used by :answers and
        # :options below -- the established (if unfashionable) route-name
        # shape here. The action itself refuses on a started game and on a
        # level's last remaining code; see QuestionsController#delete.
        member do
          delete :delete
        end

        resources :answers do
          member do
            delete :delete
          end
        end

        # Quiz options, mirroring :answers exactly -- including the :delete
        # route name, which is the established (if unfashionable) shape here.
        resources :options, only: [ :index, :create ] do
          member do
            delete :delete
          end

          # Translating options is a bulk edit of the whole list for one
          # locale, not an edit of one record, so it hangs off the collection.
          # Options are the only translatable record with no edit screen of
          # its own -- they live entirely on their question's index page.
          collection do
            patch :translations
          end
        end
      end
    end

    # AI translation of author-written content. Superadmin-only; nested under
    # the game because every action needs the game in scope and the redirect
    # target is the game's edit screen.
    #
    # POST for cancel, not DELETE: this app has no Turbo and no rails-ujs, so
    # the view drives it with a real button_to form.
    resources :translation_runs, :only => [ :new, :create, :show ] do
      post :cancel, :on => :member
      # Re-enters the SAME run rather than creating a second one. The runner's
      # resumability is scoped to a run's own proposals, so this is the only
      # route that can pick up where a failed run stopped instead of paying
      # for the whole game a second time.
      post :retry,  :on => :member

      resources :proposals, :only => [ :index ],
                            :controller => "translation_proposals" do
        member do
          post :accept
          post :reject
        end
        post :accept_all, :on => :collection
        # The flagged ones, for a reviewer who has read them. Separate from
        # accept_all deliberately -- see the actions.
        post :accept_flagged, :on => :collection
      end
    end
  end

  # Live-game interventions. Team-scoped ones carry both ids because the
  # operator acts on one team's passing within one game.
  post "/games/:game_id/pause",  to: "interventions#pause",  as: :pause_game
  post "/games/:game_id/resume", to: "interventions#resume", as: :resume_game
  post "/games/:game_id/teams/:team_id/move",        to: "interventions#move",        as: :move_team
  post "/games/:game_id/teams/:team_id/reinstate",   to: "interventions#reinstate",   as: :reinstate_team
  post "/games/:game_id/teams/:team_id/reset_clock", to: "interventions#reset_clock", as: :reset_team_clock

  # Level-scoped, unlike the team-scoped interventions above: how a level's
  # codes count is a property of the level, not of one team's passing.
  post "/games/:game_id/levels/:id/allow_any_code",    to: "interventions#allow_any_code",    as: :allow_any_code_level
  post "/games/:game_id/levels/:id/require_all_codes", to: "interventions#require_all_codes", as: :require_all_codes_level

  # Commercial entitlements. Nested under the game because every action is
  # about one game's passes, and the authorization asks about that game.
  resources :games, only: [] do
    resources :access_passes, only: [ :index, :create, :destroy ]
    # The secrets that create those passes. A separate screen rather than more
    # sections on the pass console: passes and codes answer different
    # questions and both lists grow.
    resources :access_codes, only: [ :index, :create ] do
      collection do
        # Each takes EITHER code_id OR batch_key -- one rule, two scopes. See
        # the controller's targeted_codes.
        patch :revoke
        patch :unrevoke
        patch :expiry
      end
    end
  end

  # One global form: the code carries its own game, so a customer holding a
  # card need not find the game first.
  get  "/redeem", to: "access_code_redemptions#new",    as: :redeem_access_code
  post "/redeem", to: "access_code_redemptions#create"

  # The routes below have no `resources` equivalent: in Merb they were only
  # reachable through the catch-all `default_routes` entry
  # (`match("/:controller(/:action(/:id))(.:format)")`) at the bottom of
  # config/router.rb, which Rails has no equivalent of. Each is added in the
  # same /:controller/:action/:id segment order Merb used (action before id).
  # All three below mutate state (start_test/finish_test/end_game all change
  # a game's lifecycle, and finish_test also deletes every passing and log
  # line for it), so they are POST, driven by button_to in app/views -- this
  # app has no Turbo and no rails-ujs, so a plain GET link_to would have left
  # them reachable, unprotected by CSRF, from any crafted or prefetched link.
  post "/games/start_test/:id",  to: "games#start_test",  as: :start_test_game
  post "/games/finish_test/:id", to: "games#finish_test", as: :finish_test_game
  post "/games/end_game/:id",    to: "games#end_game",    as: :end_game_game

  # Test-run invitations. All mutations are POST driven by button_to/form_tag,
  # for the same reason recorded just above for start_test/finish_test/
  # end_game: this app has no Turbo and no rails-ujs, so a GET link_to would
  # leave them reachable, unprotected by CSRF, from any crafted or prefetched
  # link.
  post "/games/:game_id/test_admissions/team",       to: "test_admissions#create_team",   as: :test_admit_team
  post "/games/:game_id/test_admissions/player",     to: "test_admissions#create_player", as: :test_admit_player
  post "/games/:game_id/test_admissions/:id/revoke", to: "test_admissions#revoke",        as: :revoke_test_admission
  post "/games/:game_id/test_token",                 to: "test_admissions#reset_token",   as: :reset_test_token

  # The link half. GET only CONFIRMS -- it renders a page carrying a POST
  # button -- because this URL is designed to be pasted into a chat, where a
  # link-preview bot that follows it would otherwise silently admit whatever
  # account it is authenticated as.
  get  "/games/:game_id/test/:token", to: "test_admissions#invite", as: :test_invite
  post "/games/:game_id/test/:token", to: "test_admissions#join",   as: :join_test

  post "/game_passings/exit_game/:game_id", to: "game_passings#exit_game", as: :exit_game

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

  post "/invitations/accept/:id", to: "invitations#accept", as: :accept_invitation
  post "/invitations/reject/:id", to: "invitations#reject", as: :reject_invitation

  post "/game_entries/new/:game_id/:team_id", to: "game_entries#new", as: :new_game_entry
  post "/game_entries/reopen/:id", to: "game_entries#reopen", as: :reopen_game_entry
  post "/game_entries/accept/:id", to: "game_entries#accept", as: :accept_game_entry
  post "/game_entries/reject/:id", to: "game_entries#reject", as: :reject_game_entry
  post "/game_entries/recall/:id", to: "game_entries#recall", as: :recall_game_entry
  post "/game_entries/cancel/:id", to: "game_entries#cancel", as: :cancel_game_entry

  # Gameplay paths are load-bearing: they appear in features and in links
  # players have bookmarked. Keep them exactly as Merb served them.
  get  "/play/:game_id/tip", to: "game_passings#get_current_level_tip", as: :get_current_level_tip
  get  "/play/:game_id",     to: "game_passings#show_current_level",    as: :show_current_level
  post "/play/:game_id",     to: "game_passings#post_answer",           as: :post_answer
  post "/play/:game_id/content_locale", to: "game_passings#set_content_locale", as: :set_content_locale

  # Two explicit routes, not the `/stats/:action/:game_id` the Merb app served.
  #
  # The dynamic :action segment is deprecated in Rails 8.0 and removed in 8.1,
  # but the reason to replace it is not the deprecation. It mapped ANY action on
  # GamePassingsController, so GET /stats/exit_game/7 reached #exit_game and
  # GET /stats/post_answer/7 reached #post_answer -- state-changing actions over
  # GET, with no CSRF token. A captain who followed a crafted link, or whose
  # browser prefetched one, quit their team out of a live game.
  #
  # Both URLs below are byte-identical to what Merb served, so bookmarks still
  # resolve (spec/routing_spec.rb pins both).
  get "/stats/index/:game_id",        to: "game_passings#index", as: :game_stats
  get "/stats/show_results/:game_id", to: "game_passings#show_results"
  get "/logs/livechannel/:game_id",     to: "logs#show_live_channel", as: :show_live_channel # прямой эфир
  get "/logs/level/:game_id/:team_id",  to: "logs#show_level_log",    as: :show_level_log    # лог по уровню
  get "/logs/game/:game_id/:team_id",   to: "logs#show_game_log",     as: :show_game_log     # лог по игре
  get "/logs/full/:game_id",            to: "logs#show_full_log",     as: :show_full_log     # полный лог по игре
end
