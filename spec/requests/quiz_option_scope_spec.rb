require "rails_helper"

# post_options built the echoed answer string from unvalidated option ids, so a
# player on any quiz level could read back the text of options belonging to
# levels they had not reached and to other games -- free, unlimited, and with
# no penalty charged because the question id matched nothing.
describe "quiz option submission scoping", type: :request do
  let(:author)   { create_user }
  let(:game) do
    g = create_game(:author => author, :is_draft => false)
    g.update_column(:starts_at, 1.hour.ago)
    g
  end
  let(:level)    { create_quiz_level(:game => game) }
  let(:question) { create_question(:level => level) }
  let(:passing)  { create_game_passing(:level => level) }
  let(:player) do
    u = create_user
    u.update!(:team => passing.team)
    passing.team.update!(:captain => u)
    u
  end

  let!(:mine) { create_option(:question => question, :text => "МОЙ ВАРИАНТ", :is_correct => true) }

  # A question on a different game entirely.
  let(:foreign_level)    { create_quiz_level }
  let(:foreign_question) { create_question(:level => foreign_level) }
  let!(:foreign_option) do
    create_option(:question => foreign_question, :text => "ЧУЖОЙ СЕКРЕТ", :is_correct => true)
  end

  before do
    passing
    put login_path, :params => { :email => player.email, :password => "1234" }
  end

  it "does not echo the text of options from another game" do
    post post_answer_path(:game_id => game.id),
         :params => { :option_ids => { foreign_question.id.to_s => [ foreign_option.id.to_s ] } }

    expect(response.body).not_to include("ЧУЖОЙ СЕКРЕТ")
  end

  # A foreign question_id/option_id resolves to nothing under the scoped
  # Option.where above, so chosen_texts stays empty -- indistinguishable, by
  # construction, from a genuinely empty submission (see
  # GamePassingsController#post_options). Before the reject-empty-answer fix
  # this still wrote a blank Log row (never leaking the foreign text, just
  # logging ""); now it is refused outright by the same guard that rejects
  # "nothing selected", so no row is written at all -- a strictly narrower
  # surface, not a regression.
  it "does not log the text of options from another game" do
    expect {
      post post_answer_path(:game_id => game.id),
           :params => { :option_ids => { foreign_question.id.to_s => [ foreign_option.id.to_s ] } }
    }.not_to change { Log.count }

    expect(response.body).not_to include("ЧУЖОЙ СЕКРЕТ")
  end

  it "still records a genuine selection on this level" do
    post post_answer_path(:game_id => game.id),
         :params => { :option_ids => { question.id.to_s => [ mine.id.to_s ] } }

    expect(Log.last.answer).to include("МОЙ ВАРИАНТ")
  end
end
