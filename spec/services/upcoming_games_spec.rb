require "rails_helper"

describe UpcomingGames do
  def scheduled_at(time, name)
    game = create_game(:name => name)
    set_game_schedule!(game, :starts_at => time)
    game
  end

  it "takes the earliest scheduled game as the next game, the rest as rows in start order" do
    late  = scheduled_at(3.days.from_now, "Поздняя")
    early = scheduled_at(1.day.from_now, "Ранняя")
    mid   = scheduled_at(2.days.from_now, "Средняя")

    result = UpcomingGames.call

    expect(result.next_game).to eq(early)
    expect(result.scheduled).to eq([mid, late])
  end

  it "puts running games first and gated games last" do
    running = create_game(:name => "Идущая")
    set_game_schedule!(running, :starts_at => 1.hour.ago)
    gated = create_game(:name => "Платная", :access_mode => "pass_required")
    upcoming = scheduled_at(1.day.from_now, "Будущая")

    result = UpcomingGames.call

    expect(result.running).to eq([running])
    expect(result.next_game).to eq(upcoming)
    expect(result.gated).to eq([gated])
    expect(result.games).to eq([running, upcoming, gated])
  end

  it "sorts a scheduled game with no start date after dated ones" do
    undated = create_game(:name => "Без даты")
    set_game_schedule!(undated, :starts_at => nil)
    dated = scheduled_at(5.days.from_now, "С датой")

    result = UpcomingGames.call

    expect(result.next_game).to eq(dated)
    expect(result.scheduled).to eq([undated])
  end

  it "caps the rows at four, filling running, then scheduled, then gated" do
    2.times { |i| set_game_schedule!(create_game(:name => "Идёт #{i}"), :starts_at => (i + 1).hours.ago) }
    5.times { |i| scheduled_at((i + 1).days.from_now, "План #{i}") }
    create_game(:name => "Код", :access_mode => "pass_required")

    result = UpcomingGames.call

    expect(result.running.size).to eq(2)
    expect(result.next_game.name).to eq("План 0")
    expect(result.scheduled.map(&:name)).to eq(["План 1", "План 2"])
    expect(result.gated).to eq([])
    expect(result.running.size + result.scheduled.size + result.gated.size).to eq(UpcomingGames::ROW_LIMIT)
  end

  it "leaves out finished, draft, withdrawn and test-run games" do
    finished = create_game(:name => "Прошла")
    set_game_schedule!(finished, :starts_at => 2.days.ago, :author_finished_at => 1.day.ago)
    create_game(:name => "Черновик", :is_draft => true)
    create_game(:name => "Снята").update_column(:withdrawn_at, Time.now)
    testing = create_game(:name => "Тест")
    set_game_schedule!(testing, :starts_at => 1.hour.ago, :is_testing => true)

    expect(UpcomingGames.call.games).to eq([])
    expect(UpcomingGames.call).to be_empty
  end

  it "costs the same number of queries for three games as for thirty" do
    3.times { |i| scheduled_at((i + 1).days.from_now, "A#{i}") }
    small = count_queries { UpcomingGames.call.games.each(&:current_run) }
    27.times { |i| scheduled_at((i + 10).days.from_now, "B#{i}") }
    large = count_queries { UpcomingGames.call.games.each(&:current_run) }

    expect(large).to eq(small)
  end
end
