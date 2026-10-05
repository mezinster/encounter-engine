module AdminHelper
  # Which admin section the current page belongs to, for the tab bar's
  # aria-current. Keyed by controller_name: entries belong to Games, team
  # adjustments to Teams.
  ADMIN_TAB_FOR_CONTROLLER = {
    "dashboard"        => :dashboard,
    "games"            => :games,
    "game_entries"     => :games,
    "users"            => :users,
    "teams"            => :teams,
    "team_adjustments" => :teams,
    "audit"            => :audit,
    "settings"         => :settings,
    "load_tests"       => :load_test,
    "styleguide"       => :styleguide
  }.freeze

  def admin_tab_current
    ADMIN_TAB_FOR_CONTROLLER.fetch(controller_name, :dashboard)
  end
end
