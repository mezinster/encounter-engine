require "rails_helper"

# Merb-era validation messages are whole sentences, but most carry no terminal
# punctuation ("…превышает заданное число"); a few end in ":-)". Joining them
# with to_sentence glued sentences with "и"; a bare space join ran them
# together. SentenceJoin gives each a terminal mark if it lacks one.
describe SentenceJoin do
  it "adds a full stop to a sentence that has no terminal punctuation" do
    expect(SentenceJoin.call(["Вы не ввели название", "Игра объявляет языки"]))
      .to eq("Вы не ввели название. Игра объявляет языки.")
  end

  it "leaves a sentence that already ends in punctuation alone, smileys included" do
    expect(SentenceJoin.call(["Вы выбрали дату из прошлого. Так нельзя :-)", "Готово!", "Правда?"]))
      .to eq("Вы выбрали дату из прошлого. Так нельзя :-) Готово! Правда?")
  end

  it "ignores trailing whitespace when deciding" do
    expect(SentenceJoin.call(["Нет команды  "])).to eq("Нет команды.")
  end

  it "returns an empty string for no messages" do
    expect(SentenceJoin.call([])).to eq("")
  end
end
