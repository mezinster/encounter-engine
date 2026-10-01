# app/services/upcoming_games.rb
#
# The games the home page shows, in the order it shows them: running games
# first (a player opening the site on game night wants the live one), then the
# earliest scheduled game as the prominent card, then other scheduled games by
# start time, then code-gated games, which have no start date. At most
# ROW_LIMIT rows besides the card; everything else is behind "Список игр".
#
# One query for the games and one for their runs (Game#status reads the
# current run, so runs are preloaded), however many games exist. Classification
# happens in memory because Game#status is the single source of truth for what
# a game's state is -- re-deriving it in SQL would drift from it.
class UpcomingGames
  ROW_LIMIT = 4

  Result = Struct.new(:running, :next_game, :scheduled, :gated, :keyword_init => true) do
    def games
      [*running, next_game, *scheduled, *gated].compact
    end

    def empty?
      games.empty?
    end
  end

  def self.call(scope = Game.visible)
    new(scope).call
  end

  def initialize(scope)
    @scope = scope
  end

  def call
    by_status = @scope.includes(:runs).to_a.group_by(&:status)

    running   = by_start(by_status.fetch(:running, []))
    scheduled = by_start(by_status.fetch(:scheduled, []))
    gated     = by_status.fetch(:available, []).sort_by { |game| [game.name.to_s, game.id] }
    next_game = scheduled.shift

    rows = (running + scheduled + gated).first(ROW_LIMIT)
    Result.new(:running   => running   & rows,
               :next_game => next_game,
               :scheduled => scheduled & rows,
               :gated     => gated     & rows)
  end

  private

  # A listed game may have no start date yet; it sorts after every dated one.
  def by_start(games)
    games.sort_by { |game| [game.starts_at ? 0 : 1, game.starts_at || Time.at(0), game.id] }
  end
end
