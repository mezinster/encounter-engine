require "rails_helper"

# What a team is told about the answer it just submitted.
#
# The reported bug: a correct code advances the level, and #post_answer then
# renders show_current_level for the NEXT level with @answer and
# @answer_was_correct still describing the level just left. So "Код 'Рецепт
# суши' -- верный." sat pinned under a question about penicillin, reading as
# though it were feedback on the question on screen.
#
# The message itself cannot simply be dropped when the level advances:
# features/game-passing/stepping-next-level.feature:26-27 is frozen and
# requires "Код 'enstart' -- верный" and "Задание #2" on the SAME rendered
# page. So it is named instead -- it says which task it belongs to -- and it
# is marked for the client-side dismissal that takes it off the screen a few
# seconds later.
describe "answer feedback", type: :request do
  let(:author)  { create_user }
  let(:game)    { g = create_game(:author => author, :is_draft => false); set_game_schedule!(g, :starts_at => 1.hour.ago); g }
  let(:passing) { create_game_passing(:level => first_level) }
  let(:player) do
    u = create_user
    u.update!(:team => passing.team)
    passing.team.update!(:captain => u)
    u
  end

  before do
    passing
    put login_path, :params => { :email => player.email, :password => "1234" }
  end

  describe "a correct code that moves the team on" do
    let!(:first_level)  { create_level(:game => game, :correct_answer => "enstart") }
    let!(:second_level) { create_level(:game => game, :correct_answer => "enfinish") }

    it "says which task the code belonged to" do
      post post_answer_path(:game_id => game.id), :params => { :answer => "enstart" }

      expect(response.body).to include(
        I18n.t("game_passings.show_current_level.level_passed", :position => first_level.position))
    end

    # The frozen contract, pinned here too so a future edit to the flash cannot
    # break it without this file going red alongside the feature.
    it "still carries the message the acceptance suite asserts" do
      post post_answer_path(:game_id => game.id), :params => { :answer => "enstart" }

      expect(response.body).to include("Код &#39;enstart&#39; -- верный")
      expect(response.body).to include("#{I18n.t('game_passings.show_current_level.level_label')} #2")
    end

    # The half that actually takes it off the screen. rack-test runs no
    # JavaScript, so this asserts the hook the script keys on, not the effect.
    it "marks the message for dismissal" do
      post post_answer_path(:game_id => game.id), :params => { :answer => "enstart" }

      expect(response.body).to include("data-dismiss-after")
    end
  end

  describe "a correct code on a level with another code still to find" do
    let!(:first_level)  { create_level(:game => game, :correct_answer => "tr1111") }
    let!(:second_code)  { create_question(:level => first_level, :correct_answer => "tr2222") }
    let!(:second_level) { create_level(:game => game, :correct_answer => "enfinish") }

    # any_code_passes defaults to TRUE (db/schema.rb), which makes one correct
    # code enough and advances the team -- the opposite of what this example is
    # about. features/multi-questional-levels/playing-with-additional-codes
    # .feature drives the same level shape.
    before { first_level.update_column(:any_code_passes, false) }

    # Nothing moved, so the message is feedback on the question on screen --
    # it is neither stale nor misplaced, and it must not vanish while the team
    # is still working on the same task.
    it "is not labelled with a task and is not dismissed" do
      post post_answer_path(:game_id => game.id), :params => { :answer => "tr1111" }

      expect(response.body).to include("Код &#39;tr1111&#39; -- верный")
      expect(response.body).not_to include("data-dismiss-after")
      expect(response.body).not_to include(
        I18n.t("game_passings.show_current_level.level_passed", :position => first_level.position))
    end
  end

  # A quiz level offers radio buttons, and #post_options joins the chosen
  # option TEXTS into @answer. Reporting that through the code message called
  # a pressed radio button a "код": «Код 'Гарнитура' -- верный». No feature
  # covers the quiz path -- the frozen set predates the feature -- so the
  # wording is free to say what actually happened.
  describe "a quiz level" do
    let!(:first_level)  { create_quiz_level(:game => game) }
    let!(:question)     { create_question(:level => first_level) }
    let!(:right)        { create_option(:question => question, :text => "Гарнитура", :is_correct => true) }
    let!(:wrong)        { create_option(:question => question, :text => "Рация") }
    # So a correct pick advances rather than finishing the game -- show_results
    # carries no answer flash at all, and there would be nothing to assert.
    let!(:second_level) { create_level(:game => game, :correct_answer => "enfinish") }

    it "reports a correct pick as a choice, not as a code" do
      post post_answer_path(:game_id => game.id),
           :params => { :option_ids => { question.id.to_s => [ right.id.to_s ] } }

      expect(response.body).to include("Ответ &#39;Гарнитура&#39; -- верный")
      expect(response.body).not_to include("Код &#39;Гарнитура&#39;")
    end

    it "reports a wrong pick as a choice, not as a code" do
      post post_answer_path(:game_id => game.id),
           :params => { :option_ids => { question.id.to_s => [ wrong.id.to_s ] } }

      expect(response.body).to include("Ответ неверный, вы выбрали &#39;Рация&#39;")
      expect(response.body).not_to include("Код неверный")
    end
  end
end
