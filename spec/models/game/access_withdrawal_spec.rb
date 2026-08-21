require "rails_helper"

# An operator may not stop selling access to a game while teams are still
# holding access they paid for and have not used.
#
# Measured before this existed: converting a gated game back to "scheduled"
# left every paying customer locked out, silently and permanently. Their pass
# stayed live for ever (nothing spends it), so it never even showed as
# consumed in the access console -- and /play refused them twice over: while
# the converted game's start date was still ahead, with "Нельзя играть в игру
# до её начала", and afterwards with "Ваша команда не зарегистрирована на эту
# игру". Neither message mentions a pass. A team caught MID-RUN lost their
# half-finished attempt the same way: the row survives, runless, reachable by
# no route at all, because find_or_create_game_passing stops consulting
# #gated_passing the moment pass_required? goes false.
#
# The fix refuses the conversion rather than guessing what a customer is owed:
# an unused pass may deserve a refund, and only a human can decide that.
describe Game, "withdrawing paid access" do
  let(:level) { create_level }
  let(:game) do
    g = level.game
    g.update!(:visibility => "listed", :access_mode => "pass_required")
    set_game_schedule!(g, :starts_at => 3.days.from_now)
    g.reload
  end

  def attempt_for(pass)
    create_game_passing(:game => pass.game, :team => pass.team, :level => level,
                        :game_run => nil, :access_pass => pass)
  end

  it "refuses the conversion while a team holds unused access" do
    create_access_pass(:game => game, :team => create_team)

    game.access_mode = "scheduled"

    expect(game).not_to be_valid
    expect(game.errors[:access_mode]).to be_present
  end

  it "says how many teams are still owed, so the operator knows the size of the job" do
    2.times { create_access_pass(:game => game, :team => create_team) }

    game.access_mode = "scheduled"
    game.valid?

    expect(game.errors[:access_mode]).to include(
      I18n.t("activerecord.errors.models.game.attributes.access_mode.access_still_owed", :count => 2)
    )
  end

  it "refuses while a team is mid-run, which is the case that loses a real attempt" do
    pass = create_access_pass(:game => game, :team => create_team)
    attempt_for(pass)

    game.access_mode = "scheduled"

    expect(game).not_to be_valid
  end

  it "allows the conversion once every pass has been used" do
    pass = create_access_pass(:game => game, :team => create_team)
    attempt_for(pass).update!(:finished_at => Time.now)

    game.access_mode = "scheduled"

    expect(game).to be_valid
  end

  it "allows the conversion once the passes are revoked" do
    pass = create_access_pass(:game => game, :team => create_team)
    pass.update!(:revoked_at => Time.now)

    game.access_mode = "scheduled"

    expect(game).to be_valid
  end

  # The escape hatch. A pass whose attempt an operator ended can be neither
  # spent nor revoked, so without this the game could never be converted.
  it "allows the conversion when the only attempt was ended by an operator" do
    pass = create_access_pass(:game => game, :team => create_team)
    attempt_for(pass).end!

    game.access_mode = "scheduled"

    expect(game).to be_valid
  end

  it "allows a game that never sold access to be converted" do
    game.access_mode = "scheduled"

    expect(game).to be_valid
  end

  # The guard is on the CONVERSION, not on the game: an ordinary save of a
  # gated game that is still selling access must not be refused just because
  # somebody holds a pass. That would lock the operator out of editing their
  # own live game.
  it "leaves an ordinary save of a still-gated game alone" do
    create_access_pass(:game => game, :team => create_team)

    game.name = "Renamed while selling"

    expect(game).to be_valid
  end
end
