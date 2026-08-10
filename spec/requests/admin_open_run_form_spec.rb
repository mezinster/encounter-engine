# -*- encoding : utf-8 -*-
require "rails_helper"

# The open-a-run form's two datetime fields are native <input
# type="datetime-local">, so every browser supplies its own picker.
#
# The game form (games/new, games/edit) uses a Merb-era Calendar.setup widget
# instead, bound to a text field by element id. That cannot be reused here: the
# console renders one form PER ROW, and a widget keyed on a single id would
# need N setup calls and N unique button ids to attach to. A native input needs
# neither, and needs no JavaScript at all.
describe "the open-a-run form on the admin console", type: :request do
  let(:author)   { create_user }
  let(:operator) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:game) do
    g = create_game(:author => author, :is_draft => false)
    create_level(:game => g)
    set_game_schedule!(g, :starts_at => 2.days.ago, :author_finished_at => 1.day.ago)
    g
  end

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def form_html
    listed = game
    sign_in(operator)
    get admin_games_path
    Capybara.string(response.body).find("form[action='#{open_run_admin_game_path(listed)}']")
  end

  it "offers a date-and-time picker for the run's start" do
    field = form_html.find("input[name='starts_at']", :visible => :all)

    expect(field[:type]).to eq("datetime-local")
  end

  # A run with no start date never starts: Game#started? reads nil as "not
  # yet", so the game would sit scheduled for ever while the operator was told
  # the run had opened. An empty datetime-local submits "", so this is one
  # stray Enter away -- guarded in the browser AND on the server.
  it "marks the start required in the browser" do
    field = form_html.find("input[name='starts_at']", :visible => :all)

    expect(field[:required]).to be_present
  end

  it "refuses a blank start on the server too" do
    sign_in(operator)

    expect {
      post open_run_admin_game_path(game),
           :params => { :starts_at => "", :registration_deadline => "", :max_team_number => "10" }
    }.not_to change { game.runs.reload.count }

    expect(flash[:alert]).to be_present
  end

  # A game with no registration deadline is a real, existing state, so the
  # deadline stays optional.
  it "opens a run with no registration deadline" do
    sign_in(operator)

    expect {
      post open_run_admin_game_path(game),
           :params => { :starts_at => 2.years.from_now.strftime("%Y-%m-%dT%H:%M"),
                        :registration_deadline => "", :max_team_number => "10" }
    }.to change { game.runs.reload.count }.by(1)
  end

  it "offers a date-and-time picker for the registration deadline" do
    field = form_html.find("input[name='registration_deadline']", :visible => :all)

    expect(field[:type]).to eq("datetime-local")
  end

  # A numeric field gets the numeric keypad on a phone, and rejects "ten"
  # before the request is made rather than after.
  it "offers a numeric field for the team cap" do
    field = form_html.find("input[name='max_team_number']", :visible => :all)

    expect(field[:type]).to eq("number")
    expect(field[:min]).to eq("1")
  end

  it "prefills the team cap from the previous run" do
    game.current_run.update_column(:max_team_number, 42)

    field = form_html.find("input[name='max_team_number']", :visible => :all)

    expect(field[:value]).to eq("42")
  end

  # datetime-local submits YYYY-MM-DDTHH:MM. The action must accept that
  # unchanged -- it is what every browser sends, and nothing in between
  # reformats it.
  it "accepts the value format a datetime-local input submits" do
    sign_in(operator)
    starts = 2.years.from_now

    expect {
      post open_run_admin_game_path(game),
           :params => { :starts_at => starts.strftime("%Y-%m-%dT%H:%M"),
                        :registration_deadline => 23.months.from_now.strftime("%Y-%m-%dT%H:%M"),
                        :max_team_number => "10" }
    }.to change { game.runs.reload.count }.by(1)

    expect(game.reload.current_run.starts_at).to be_within(1.minute).of(starts)
  end
end
