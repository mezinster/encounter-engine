require "rails_helper"

# Every checkbox and radio on the author-facing forms is a full-size
# <label class="check"> row: the whole row is the tap target, and the label
# text is the control's accessible name. Quiz options and the drawer toggle
# are built differently on purpose and are skipped.
describe "checkbox and radio rows", :type => :request do
  def sign_in(user)
    post login_path, :params => { :email => user.email, :password => "1234" }
  end

  def doc
    Nokogiri::HTML(response.body)
  end

  def controls(document)
    document.css("input[type=checkbox], input[type=radio]").reject do |input|
      input["id"] == "drawer-state" || input.ancestors(".quiz-option").any?
    end
  end

  def label_of(input)
    input.ancestors("label.check").first
  end

  def text_of(label)
    label.text.gsub(/\s+/, " ").strip
  end

  def expect_every_control_in_a_check_row(document)
    found = controls(document)
    expect(found).not_to be_empty
    found.each do |input|
      expect(label_of(input)).not_to be_nil, "#{input['name']} is not inside label.check"
    end
    found.map { |input| text_of(label_of(input)) }
  end

  let(:author) { create_user }
  let(:game)   { create_game(:author => author) }

  before { sign_in(author) }

  [ :new, :edit ].each do |kind|
    it "renders the #{kind} game form's controls as check rows" do
      get(kind == :new ? new_game_path : edit_game_path(game))

      texts = expect_every_control_in_a_check_row(doc)
      expect(texts).to include("Черновик?", "Начислять очки", "Русский")

      draft = doc.css("label.check").find { |l| text_of(l) == "Черновик?" }
      expect(draft.at_css("input[type=checkbox][name='game[visibility]']")).not_to be_nil
    end
  end

  it "renders the level form's radios as check rows" do
    get new_game_level_path(game)
    texts = expect_every_control_in_a_check_row(doc)
    expect(texts).to include("Достаточно любого из кодов", "Нужно найти все коды")

    level = create_level(:game => game)
    get edit_game_level_path(game, level)
    texts = expect_every_control_in_a_check_row(doc)
    expect(texts).to include("Достаточно любого из кодов")
  end

  it "renders the option form's correct-answer box as a check row" do
    level = create_level(:game => game)
    question = create_question(:level => level)
    get game_level_question_options_path(game, level, question)

    texts = expect_every_control_in_a_check_row(doc)
    expect(texts).to include("Это верный ответ")
  end

  it "renders the messenger boxes on the profile form as check rows" do
    get edit_user_path(author)
    texts = expect_every_control_in_a_check_row(doc)
    expect(texts).to include("Telegram", "WhatsApp", "Viber", "Signal", "MAX")
  end

  it "renders the translation run's locale boxes as check rows" do
    superadmin = create_user
    superadmin.update!(:is_superadmin => true)
    allow(Translation::Client).to receive(:configured?).and_return(true)
    sign_in(superadmin)

    get new_game_translation_run_path(game)
    texts = expect_every_control_in_a_check_row(doc)
    expect(texts).to include("English")
  end

  it "names each file picker checkbox by its filename" do
    file  = create_game_file(:game => game, :filename => "plan.jpg")
    level = create_level(:game => game)
    get edit_game_level_path(game, level)

    box = doc.at_css("#game_file_#{file.id}")
    expect(box).not_to be_nil
    expect(text_of(label_of(box))).to eq("plan.jpg")
  end
end
