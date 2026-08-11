# -*- encoding : utf-8 -*-
require "rails_helper"

# The reported symptom, driven over HTTP: an instance whose only game is
# finished, with nothing running, reporting "Прохождений идёт: 3".
#
# The overview counted `GamePassing.where(finished_at: nil)`, and
# GamePassing#end! sets status "ended" without stamping finished_at -- so
# every team the author ended by pressing "ЗАВЕРШИТЬ ИГРУ" stayed in that
# figure permanently, and every game ended afterwards added more.
describe "the admin overview's passing outcomes", type: :request do
  let(:author)     { create_user }
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:game) do
    g = create_game(:author => author, :is_draft => false)
    set_game_schedule!(g, :starts_at => 1.hour.ago)
    g
  end
  let(:level) { create_level(:game => game) }

  def passing(attrs = {})
    create_game_passing({ :level => level, :game_run => game.current_run }.merge(attrs))
  end

  def count_for(key)
    label = I18n.t("admin.dashboard.show.total.#{key}")
    # The tile is <div class="stat-value">N</div> above <div
    # class="stat-label">Label</div>, so the number is the one preceding this
    # label in the rendered page.
    response.body[%r{<div class="stat-value">(\d+)</div>\s*<div class="stat-label">#{Regexp.escape(label)}</div>}, 1].to_i
  end

  before { put login_path, :params => { :email => superadmin.email, :password => "1234" } }

  # The exact shape of the screenshot this came from: four teams, one across
  # the line, three still out on the course when the author closed the game.
  it "reports nothing in progress once the author has ended the game" do
    finisher = passing(:finished_at => Time.now)
    3.times { passing }

    # The real path: GamesController#end_game over HTTP, not end! by hand.
    put login_path, :params => { :email => author.email, :password => "1234" }
    post end_game_game_path(game)
    put login_path, :params => { :email => superadmin.email, :password => "1234" }

    get admin_dashboard_path

    expect(response).to have_http_status(:ok)
    expect(count_for(:passings_in_progress)).to eq(0)
    expect(count_for(:passings_interrupted)).to eq(3)
    # The team that crossed the line stays finished, even though end_game
    # stamped "ended" over it as well -- end! skips only exited passings.
    expect(count_for(:passings_finished)).to eq(1)
    expect(finisher.reload.status).to eq("ended")
  end

  it "still reports a team that is genuinely playing" do
    passing

    get admin_dashboard_path

    expect(count_for(:passings_in_progress)).to eq(1)
    expect(count_for(:passings_interrupted)).to eq(0)
    expect(count_for(:passings_finished)).to eq(0)
  end

  # exit! stamps finished_at, so this used to be filed beside teams that
  # actually completed the course.
  it "files a team that walked off the course under interrupted" do
    passing.exit!

    get admin_dashboard_path

    expect(count_for(:passings_interrupted)).to eq(1)
    expect(count_for(:passings_finished)).to eq(0)
  end

  it "shows the three tiles adding up to every passing on the instance" do
    passing(:finished_at => Time.now)
    passing.exit!
    passing.end!
    passing

    get admin_dashboard_path

    total = count_for(:passings_finished) +
            count_for(:passings_interrupted) +
            count_for(:passings_in_progress)

    expect(total).to eq(GamePassing.count)
  end
end
