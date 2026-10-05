module AdminHelper
  # Which admin section the current page belongs to, for the tab bar's
  # aria-current. Keyed by controller_name: entries belong to Games, team
  # adjustments to Teams. No default: a new admin controller missing from this
  # map raises (KeyError) rather than quietly marking «Обзор» as current.
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
    ADMIN_TAB_FOR_CONTROLLER.fetch(controller_name)
  end

  # The console's status tag for a game -- one mapping for the list and the
  # game page.
  def admin_game_status_tag(game)
    case game.status
    when :withdrawn then content_tag(:span, t("admin.games.index.withdrawn"), :class => "tag tag--danger")
    when :draft     then content_tag(:span, t("admin.games.index.draft"),     :class => "tag")
    when :finished  then content_tag(:span, t("admin.games.index.finished"),  :class => "tag")
    when :available then content_tag(:span, t("admin.games.index.available"), :class => "tag")
    when :running   then content_tag(:span, t("admin.games.index.running"),   :class => "tag tag--live")
    else                 content_tag(:span, t("admin.games.index.scheduled"), :class => "tag")
    end
  end
end
