require "rails_helper"

describe "deleting a code from a level", type: :request do
  let(:author) { create_user }
  let(:game)   { create_game(:author => author) }
  let(:level)  { create_level(:game => game) }

  before { put login_path, :params => { :email => author.email, :password => "1234" } }

  def add_code(value)
    question = Question.new(:correct_answer => value)
    question.level = level
    question.save!
    question
  end

  it "removes the code when the level has more than one" do
    extra = add_code("второй")

    expect { get delete_game_level_question_path(game, level, extra) }
      .to change { level.reload.questions.count }.from(2).to(1)

    expect(response).to redirect_to(game_level_path(game, level))
    expect(flash[:notice]).to eq(I18n.t("questions.code_deleted"))
  end

  # The same rule AnswersController#delete applies one level down: a level with
  # no codes could never be answered or completed.
  it "refuses to remove the level's last code" do
    only_question = level.questions.first

    expect { get delete_game_level_question_path(game, level, only_question) }
      .not_to change { level.reload.questions.count }

    expect(flash[:error]).to eq(I18n.t("questions.must_have_at_least_one_code"))
  end

  # answered_questions stores question ids and AnsweredQuestionsCoder drops ids
  # it can no longer resolve, so deleting a question mid-game retroactively
  # un-answers it for every team that had already found it.
  it "refuses once the game has started" do
    extra = add_code("второй")
    game.update_column(:starts_at, 1.hour.ago)

    expect { get delete_game_level_question_path(game, level, extra) }
      .not_to change { level.reload.questions.count }

    expect(response).to have_http_status(:unauthorized)
  end

  it "refuses a user who is not the author" do
    extra = add_code("второй")
    other = create_user
    put login_path, :params => { :email => other.email, :password => "1234" }

    expect { get delete_game_level_question_path(game, level, extra) }
      .not_to change { level.reload.questions.count }

    expect(response).to have_http_status(:unauthorized)
  end

  # Scoped through the level, so a question id belonging to somebody else's
  # game cannot be deleted by guessing it.
  it "404s on a question that belongs to another level" do
    foreign = create_level(:game => game).questions.first

    expect { get delete_game_level_question_path(game, level, foreign) }
      .to raise_error(ActiveRecord::RecordNotFound)
  end

  it "takes the code's answer variants with it" do
    extra = add_code("второй")
    Answer.create!(:question => extra, :value => "vtoroy")

    expect { get delete_game_level_question_path(game, level, extra) }
      .to change { Answer.where(:question_id => extra.id).count }.to(0)
  end

  # THE reason the answers must go too. Answer validates uniqueness scoped to
  # :level_id, so an orphan left behind by a deleted code would permanently
  # block re-adding that same code -- rejected by a row the author cannot see.
  it "lets the same code be added again afterwards" do
    extra = add_code("второй")
    get delete_game_level_question_path(game, level, extra)

    readded = Question.new(:correct_answer => "второй")
    readded.level = level.reload

    expect(readded).to be_valid
    expect { readded.save! }.to change { level.reload.questions.count }.from(1).to(2)
  end
end

describe "the level page's code controls", type: :view do
  let(:author) { create_user }
  let(:game)   { create_game(:author => author) }

  before do
    assign(:game, game)
    view.define_singleton_method(:current_user) { author }
    view.define_singleton_method(:logged_in?)   { true }
  end

  # One button per level, not one per code. Three identical anonymous buttons
  # gave the author no way to tell which code each belonged to.
  it "renders exactly one options link however many codes the level has" do
    level = create_level(:game => game)
    2.times { |i| q = Question.new(:correct_answer => "код#{i}"); q.level = level; q.save! }
    assign(:level, level.reload)

    render :template => "levels/show"

    expect(rendered.scan(I18n.t("levels.show.options_link")).size).to eq(1)
  end

  it "names which code the options link manages when there is more than one" do
    level = create_level(:game => game)
    q = Question.new(:correct_answer => "второй"); q.level = level; q.save!
    assign(:level, level.reload)

    render :template => "levels/show"

    expect(rendered).to include(I18n.t("levels.show.options_for_code", :code => level.questions.first.correct_answer))
  end

  it "does not name a code on an ordinary single-code level" do
    level = create_level(:game => game)
    assign(:level, level)

    render :template => "levels/show"

    expect(rendered).to include(I18n.t("levels.show.options_link"))
    expect(rendered).not_to include(
      I18n.t("levels.show.options_for_code", :code => level.questions.first.correct_answer)
    )
  end

  it "offers a delete link per code once there is more than one" do
    level = create_level(:game => game)
    q = Question.new(:correct_answer => "второй"); q.level = level; q.save!
    assign(:level, level.reload)

    render :template => "levels/show"

    # Counted by href, not by link text: delete_code ("Удалить код") is also a
    # substring of delete_code_confirm, so scanning for the text finds each
    # link twice.
    expect(rendered.scan(/\/questions\/\d+\/delete/).size).to eq(2)
  end

  # The last code cannot be deleted anyway, so the link would only ever produce
  # an error.
  it "offers no delete link on a single-code level" do
    assign(:level, create_level(:game => game))

    render :template => "levels/show"

    expect(rendered).not_to include(I18n.t("levels.show.delete_code"))
  end

  it "hides the delete links once the game has started" do
    level = create_level(:game => game)
    q = Question.new(:correct_answer => "второй"); q.level = level; q.save!
    game.update_column(:starts_at, 1.hour.ago)
    assign(:level, level.reload)

    render :template => "levels/show"

    expect(rendered).not_to include(I18n.t("levels.show.delete_code"))
  end
end
