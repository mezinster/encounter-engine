require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_record/railtie"
# Active Storage for game file libraries (see
# docs/superpowers/specs/2026-08-12-level-and-hint-attachments-design.md).
# It pulls in Active Job, which this app has no other use for — the queue
# adapter is pinned to :inline in the environment files for that reason.
require "active_storage/engine"
require "action_controller/railtie"
require "action_view/railtie"
require "action_mailer/railtie"

Bundler.require(*Rails.groups)

module EncounterEngine
  class Application < Rails::Application
    config.load_defaults 8.0

    # Platform copy is translated; game content is not. See config/locales.
    #
    # The communities this platform serves. ru and en are complete and held to
    # exact key parity by spec/i18n_spec.rb; uk and ka are complete but
    # machine-produced without a native reviewer (see CLAUDE.md).
    #
    # tr, be and pl were added on 2026-08-09 under the same "register them now,
    # translate later" move uk and ka arrived with: their files carry only the
    # locales.* endonyms, and config.i18n.fallbacks below sends every other key
    # to :ru until
    # docs/superpowers/plans/2026-08-09-locale-translation-delivery.md fills
    # each one in.
    #
    # Adding a locale here is NOT free, and not only for the switcher: several
    # views iterate this list -- users/edit, games/new, games/edit,
    # shared/_language_tabs, layouts/_header -- so a new entry widens the
    # game-authoring form by one content-translation tab, and four controllers
    # (questions, hints, levels, games) build their permitted-param maps from
    # it. The one hard requirement is locales.<code> in EVERY locale file
    # including ru.yml: that key cannot fall back, because it is missing from
    # the fallback target too. spec/i18n_spec.rb guards exactly that.
    #
    # Flipping the *default* to :en is a separate decision the project owner
    # has deferred to when the content-translation work happens -- do not
    # change it here.
    config.i18n.default_locale = :ru
    config.i18n.available_locales = [:ru, :en, :uk, :ka, :tr, :be, :pl]
    config.i18n.fallbacks = [:ru]

    # Each deployment serves one city, so the zone is per-instance, matching
    # the TZ variable create-heroku-instance already sets.
    config.time_zone = ENV.fetch("TZ", "UTC")
    config.active_record.default_timezone = :utc

    # config/initializers/filter_parameter_logging.rb is what a generated
    # Rails app ships with -- this repo never had a config/initializers
    # directory at all (Merb had no equivalent concept), so the redaction it
    # normally provides was simply missing. Without it, every login and
    # signup request logs its params -- including a plaintext password --
    # at :info, which config/environments/production.rb sets as the
    # production log level.
    config.filter_parameters += [:password, :password_confirmation, :secret, :token]

    # Active Storage draws nine routes of its own by default, including
    # POST /rails/active_storage/direct_uploads and
    # PUT  /rails/active_storage/disk/:encoded_token -- an unauthenticated write
    # path onto a disk this deployment shares with Postgres and other tenants.
    # Those controllers descend from ActiveStorage::BaseController, not
    # ApplicationController, so this app's Authentication filter never runs on
    # them.
    #
    # This app serves its own bytes through one authorized route
    # (GET /games/:game_id/files/:id/:variant, design §4), so the built-in
    # routes are not merely unused -- direct uploads are listed under "Out of
    # scope, deliberately" in the design because they bypass the upload
    # validation that IS the security model.
    #
    # Turning them off also removes blob.url / rails_blob_path, which is the
    # point: it makes it structurally impossible for a later phase to shortcut
    # the authorization matrix with a built-in signed URL.
    config.active_storage.draw_routes = false
  end
end
