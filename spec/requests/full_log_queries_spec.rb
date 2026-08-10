# -*- encoding : utf-8 -*-
require "rails_helper"

# show_full_log renders @levels as rows and @teams as columns, and called
# @logs.of_team(team).of_level(level) in each cell. @logs was an UNLOADED
# relation, so that was one query per cell -- for «Викторина» as it stood,
# 77 levels x 3 teams ≈ 231 queries on one page load.
#
# Asserted as a SLOPE rather than a magic number, the same shape
# spec/requests/admin_console_spec.rb uses: a count pinned to an exact value
# breaks on any unrelated query added elsewhere, and says nothing about
# whether it grows.
describe "the full log's query count", type: :request do
  let(:author) { create_user }
  let(:game) do
    g = create_game(:author => author, :is_draft => false)
    set_game_schedule!(g, :starts_at => 2.days.ago)
    g
  end

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def add_levels_with_logs(count, team)
    count.times do
      level = create_level(:game => game)
      create_log(:game => game, :level => level, :team => team,
                 :game_run => game.current_run, :answer => "код")
    end
  end

  it "does not grow with the number of levels" do
    team = create_team(:captain => create_user)
    create_game_passing(:level => create_level(:game => game), :team => team,
                        :game_run => game.current_run)
    sign_in(author)

    add_levels_with_logs(2, team)
    small = count_queries { get show_full_log_path(:game_id => game.id) }

    add_levels_with_logs(8, team)
    large = count_queries { get show_full_log_path(:game_id => game.id) }

    expect(large).to eq(small)
  end

  it "still renders every answer" do
    team = create_team(:captain => create_user)
    level = create_level(:game => game)
    create_game_passing(:level => level, :team => team, :game_run => game.current_run)
    create_log(:game => game, :level => level, :team => team,
               :game_run => game.current_run, :answer => "видимыйкод")
    sign_in(author)

    get show_full_log_path(:game_id => game.id)

    expect(response.body).to include("видимыйкод")
  end
end
