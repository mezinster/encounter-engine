require "rails_helper"

describe "game deletion", type: :request do
  let(:author) { create_user }

  # Verified: config/routes.rb maps GET /login to sessions#new (the form) and
  # PUT /login to sessions#update (the actual login). It is PUT, not POST.
  # create_user (spec/spec_helpers/fixtures_helper.rb) sets password "1234".
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "is allowed when no team has ever played" do
    game = create_game(:author => author, :is_draft => true)
    expect(game.deletable?).to be true
  end

  it "is refused once any team has played" do
    game = create_game(:author => author, :is_draft => false)
    create_game_passing(:level => create_level(:game => game))
    expect(game.reload.deletable?).to be false
  end

  # Finding 1 of the whole-branch review: has_many :access_passes carried
  # :dependent => :destroy while this check only ever looked at
  # game_passings, so deleting a gated game with an issued-but-unstarted pass
  # destroyed the purchase record silently -- no refusal, no audit of what
  # was lost. No game_passing exists yet in this example, so it isolates the
  # access_passes conjunct: dropping it from Game#deletable? leaves every
  # other example here green and only this one fails.
  it "is refused once a gated game holds an access pass, even with no passing yet" do
    game = create_game(:author => author, :is_draft => false, :access_mode => "pass_required")
    create_access_pass(:game => game)
    expect(game.reload.deletable?).to be false
  end

  # A ledger row is a record of something that happened, so holding one
  # blocks deletion the same way a game_passing/access_pass row does.
  #
  # An ordinary point_transaction is always earned through a game_passing
  # belonging to the same game, so the existing game_passings.empty? conjunct
  # would already refuse deletion in that case -- it would not isolate this
  # new conjunct. Deleting the earning passing out from under its award (with
  # #delete, which skips callbacks/validations, standing in for a row removed
  # independently) leaves game_passings empty while the ledger row remains,
  # so only point_transactions.empty? still refuses here.
  it "is refused once the game holds a point transaction, even with no game passing left to explain it" do
    game = create_game(:author => author, :is_draft => true)
    passing = create_game_passing(:level => create_level(:game => game))
    create_point_transaction(:passing => passing)
    passing.delete

    expect(game.reload.game_passings).to be_empty
    expect(game.point_transactions).not_to be_empty
    expect(game.deletable?).to be false
  end

  # Same discrimination as the access_passes example above, one purchase
  # record earlier in its life: an unredeemed AccessCode has not yet produced
  # a pass, so it isolates the access_codes conjunct -- dropping it from
  # Game#deletable? leaves every other example here green and only this one
  # fails.
  it "is refused once a gated game holds an access code, even unredeemed" do
    game = create_game(:author => author, :is_draft => false, :access_mode => "pass_required")
    create_access_code(:game => game)
    expect(game.reload.deletable?).to be false
  end

  # Today's behaviour orphans them: zero foreign keys, no dependent: options.
  it "takes the levels, hints, questions and answers with it" do
    game     = create_game(:author => author, :is_draft => true)
    level    = create_level(:game => game)
    hint     = create_hint(:level => level)
    question = create_question(:level => level, :correct_answer => "CODE")
    answer   = question.answers.first

    level_id, hint_id, question_id, answer_id = level.id, hint.id, question.id, answer.id

    game.destroy

    expect(Level.where(:id => level_id)).to be_empty
    expect(Hint.where(:id => hint_id)).to be_empty
    expect(Question.where(:id => question_id)).to be_empty
    # Answers are removed through Level#answers, not Question#answers: every
    # Answer carries a level_id (Answer#assign_level derives it from
    # question.level), so the level's own cascade covers them whichever
    # question they belong to. Question#answers deliberately has no
    # dependent: option -- adding one would be redundant, not safer.
    expect(Answer.where(:id => answer_id)).to be_empty
  end

  it "refuses over HTTP and leaves the game alone" do
    game = create_game(:author => author, :is_draft => false)
    create_game_passing(:level => create_level(:game => game))
    sign_in(author)

    delete_game_request(game)

    expect(Game.where(:id => game.id)).not_to be_empty
  end

  # The delete route in this app is GamesController#delete, not #destroy.
  # Confirm its verb and helper in config/routes.rb before running.
  def delete_game_request(game)
    delete delete_game_path(game)
  end
end
