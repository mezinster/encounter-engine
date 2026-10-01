require "rails_helper"

# GameRun adds the same whole-sentence messages Game does ("Вы выбрали дату из
# прошлого. Так нельзя :-)"). Without a bare `format` on game_run's fields the
# alert read "Starts at Вы выбрали…" -- the raw English column name bolted onto
# a Russian sentence -- and several of them were joined with "и". Literals are
# pinned rather than I18n.t(...), which would pass with the key missing.
describe "the open-run alert's wording", type: :request do
  let(:author)   { create_user }
  let(:operator) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:game) do
    g = create_game(:author => author, :is_draft => false)
    create_level(:game => g)
    set_game_schedule!(g, :starts_at => 2.days.ago, :author_finished_at => 1.day.ago)
    g
  end

  before { put login_path, :params => { :email => operator.email, :password => "1234" } }

  it "shows a past start date as the bare sentence" do
    post open_run_admin_game_path(game),
         :params => { :starts_at => 1.day.ago.strftime("%Y-%m-%d %H:%M"), :max_team_number => "10" }

    expect(flash[:alert]).to eq("Вы выбрали дату из прошлого. Так нельзя :-)")
  end

  it "joins two sentences with a space, not with и" do
    post open_run_admin_game_path(game),
         :params => { :starts_at => 1.day.ago.strftime("%Y-%m-%d %H:%M"),
                      :registration_deadline => 1.day.from_now.strftime("%Y-%m-%d %H:%M"),
                      :max_team_number => "10" }

    expect(flash[:alert]).to start_with("Вы выбрали дату из прошлого. Так нельзя :-) ")
    expect(flash[:alert]).not_to include(" и ")
    expect(flash[:alert]).not_to match(/Starts at|Registration deadline/)
  end
end
