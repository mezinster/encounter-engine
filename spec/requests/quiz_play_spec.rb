require "rails_helper"

describe "playing a quiz level", type: :request do
  let(:author)   { create_user }
  let(:game)     { g = create_game(:author => author, :is_draft => false); g.update_column(:starts_at, 1.hour.ago); g }
  let(:level)    { create_level(:game => game) }
  let(:question) { create_question(:level => level) }
  let(:passing)  { create_game_passing(:level => level) }
  let(:player)   do
    u = create_user
    u.update!(:team => passing.team)
    passing.team.update!(:captain => u)
    u
  end

  let!(:right) { create_option(:question => question, :text => "Париж", :is_correct => true) }
  let!(:wrong) { create_option(:question => question, :text => "Лион") }

  before do
    level.update_column(:wrong_answer_penalty, 120)
    passing
    put login_path, :params => { :email => player.email, :password => "1234" }
  end

  it "shows the options instead of a code field" do
    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Париж")
    expect(response.body).to include("Лион")
    expect(response.body).not_to include('name="answer"')
  end

  it "advances on the correct selection" do
    post post_answer_path(:game_id => game.id),
         :params => { :option_ids => { question.id.to_s => [ right.id.to_s ] } }

    expect(passing.reload.answered_questions).to include(question)
  end

  it "charges the penalty on a wrong selection and stays put" do
    post post_answer_path(:game_id => game.id),
         :params => { :option_ids => { question.id.to_s => [ wrong.id.to_s ] } }

    passing.reload
    expect(passing.penalty_seconds).to eq(120)
    expect(passing.answered_questions).to be_empty
  end

  # The author's answer log is a complete record of what teams did, for typed
  # codes and for picks alike.
  it "records the chosen option text in the log" do
    expect {
      post post_answer_path(:game_id => game.id),
           :params => { :option_ids => { question.id.to_s => [ wrong.id.to_s ] } }
    }.to change { Log.count }.by(1)

    expect(Log.last.answer).to include("Лион")
  end

  # The guarantee the whole design rests on: with no options, nothing changes.
  it "leaves a code level completely untouched" do
    code_level = create_level(:game => game, :correct_answer => "верно")
    passing.update!(:current_level => code_level)

    get show_current_level_path(:game_id => game.id)

    expect(response.body).to include('name="answer"')
  end
end
