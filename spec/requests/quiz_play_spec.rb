require "rails_helper"

describe "playing a quiz level", type: :request do
  let(:author)   { create_user }
  let(:game)     { g = create_game(:author => author, :is_draft => false); g.update_column(:starts_at, 1.hour.ago); g }
  # A pure quiz level -- create_level always builds a code question via
  # correct_answer, which would make this a MIXED level instead (see finding
  # 2 of the whole-branch review; the mixed shape gets its own describe block
  # below).
  let(:level)    { create_quiz_level(:game => game) }
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

  # A question keeps its Answer rows when an author adds options to turn it
  # into a quiz question -- AnswersController#delete refuses to remove the last
  # variant, so the pre-quiz code cannot be stripped even deliberately. Once
  # post_options learned to accept a typed answer (the fix for the mixed-level
  # defect), that stale code became a working answer to a question the screen
  # never asks a code for: submit it with no selection at all and the level
  # completes. Guarded in BOTH GamePassing#correct_answer? and
  # Level#find_question_by_answer, so both are pinned here.
  it "refuses the code a quiz question carried before it became a quiz question" do
    stale_code = question.correct_answer
    expect(stale_code).to be_present

    post post_answer_path(:game_id => game.id), :params => { :answer => stale_code }

    passing.reload
    expect(passing.answered_questions).to be_empty
    expect(passing.current_level).to eq(level)
    expect(passing.finished_at).to be_nil
  end

  # The name promised advancement but the original assertion only checked
  # that the question was recorded as answered -- deleting `pass_level! if
  # all_questions_answered?` from GamePassing#answer_options! left it green.
  # This needs a real next level to tell "advanced" apart from "the only
  # level, so it just finished" -- see finding 2 of the whole-branch review.
  it "advances current_level on the correct selection" do
    next_level = create_level(:game => game)

    post post_answer_path(:game_id => game.id),
         :params => { :option_ids => { question.id.to_s => [ right.id.to_s ] } }

    expect(passing.reload.current_level).to eq(next_level)
  end

  # The other half of "advances": the last level's only question, answered
  # correctly, has to finish the game rather than merely advance nowhere.
  it "finishes the game when the correct selection completes the last level" do
    expect(level.next).to be_nil

    post post_answer_path(:game_id => game.id),
         :params => { :option_ids => { question.id.to_s => [ right.id.to_s ] } }

    expect(passing.reload.finished_at).not_to be_nil
  end

  it "charges the penalty on a wrong selection and stays put" do
    post post_answer_path(:game_id => game.id),
         :params => { :option_ids => { question.id.to_s => [ wrong.id.to_s ] } }

    passing.reload
    expect(passing.penalty_seconds).to eq(120)
    expect(passing.answered_questions).to be_empty
  end

  # A crafted scalar (option_ids=boom) has no #each; only a real Hash behaves
  # as a selection. Anything else is treated as no selection at all, not a 500.
  it "does not 500 on a crafted scalar option_ids" do
    post post_answer_path(:game_id => game.id), :params => { :option_ids => "boom" }

    expect(response).to have_http_status(:ok)
    expect(passing.reload.current_level).to eq(level)
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

  # post_options used to call save_log AFTER answer_options!, which -- on a
  # correct, level-completing answer -- had already reassigned current_level
  # via pass_level!. The log ended up attributed to the level the team landed
  # on, not the one they actually answered on; see finding 4 of the
  # whole-branch review.
  describe "the answer log on a correct, level-advancing pick" do
    it "logs against the level the pick was made on, not the one advanced to" do
      next_level = create_level(:game => game)

      expect {
        post post_answer_path(:game_id => game.id),
             :params => { :option_ids => { question.id.to_s => [ right.id.to_s ] } }
      }.to change { Log.count }.by(1)

      expect(Log.last.level).to eq(level.name)
      expect(passing.reload.current_level).to eq(next_level)
    end

    it "still logs when the pick finishes the game outright" do
      expect(level.next).to be_nil

      expect {
        post post_answer_path(:game_id => game.id),
             :params => { :option_ids => { question.id.to_s => [ right.id.to_s ] } }
      }.to change { Log.count }.by(1)

      expect(Log.last.level).to eq(level.name)
    end
  end

  # The guarantee the whole design rests on: with no options, nothing changes.
  it "leaves a code level completely untouched" do
    code_level = create_level(:game => game, :correct_answer => "верно")
    passing.update!(:current_level => code_level)

    get show_current_level_path(:game_id => game.id)

    expect(response.body).to include('name="answer"')
  end

  # A penalty nobody can see is a penalty nobody believes, and an author
  # fielding "why did we lose?" needs to be able to point at it.
  describe "the running penalty" do
    it "shows the accrued total on the play screen once it is non-zero" do
      post post_answer_path(:game_id => game.id),
           :params => { :option_ids => { question.id.to_s => [ wrong.id.to_s ] } }

      get show_current_level_path(:game_id => game.id)

      expect(response.body).to include(I18n.t("game_passings.show_current_level.penalty_label"))
    end

    it "does not show it before anything has been charged" do
      get show_current_level_path(:game_id => game.id)

      expect(response.body).not_to include(I18n.t("game_passings.show_current_level.penalty_label"))
    end
  end

  # A level can hold a code question AND a quiz question at once -- authorable
  # in one click from levels/show.html.erb, which puts an "add options" button
  # beside every question on a multi-code level. Before this fix the level was
  # permanently unwinnable: the code field disappeared from the view and
  # post_answer discarded params[:answer] entirely. See finding 1 of the
  # whole-branch review.
  describe "a level mixing a quiz question and a code question" do
    let(:mixed_level)     { create_level(:game => game, :correct_answer => "секрет") }
    let!(:mixed_question) { create_question(:level => mixed_level) }
    let!(:mixed_right)    { create_option(:question => mixed_question, :text => "Берлин", :is_correct => true) }
    let!(:mixed_wrong)    { create_option(:question => mixed_question, :text => "Мюнхен") }
    let!(:next_level)     { create_level(:game => game) }

    before { passing.update!(:current_level => mixed_level) }

    it "renders both the quiz options and the code field" do
      get show_current_level_path(:game_id => game.id)

      expect(response.body).to include("Берлин")
      expect(response.body).to include('name="answer"')
    end

    it "does not advance from the option alone" do
      post post_answer_path(:game_id => game.id),
           :params => { :option_ids => { mixed_question.id.to_s => [ mixed_right.id.to_s ] } }

      expect(passing.reload.current_level).to eq(mixed_level)
    end

    it "does not advance from the code alone" do
      post post_answer_path(:game_id => game.id),
           :params => { :answer => "секрет" }

      expect(passing.reload.current_level).to eq(mixed_level)
    end

    it "advances once both the option and the code are answered correctly, together" do
      post post_answer_path(:game_id => game.id),
           :params => { :option_ids => { mixed_question.id.to_s => [ mixed_right.id.to_s ] },
                         :answer => "секрет" }

      expect(passing.reload.current_level).to eq(next_level)
    end
  end
end
