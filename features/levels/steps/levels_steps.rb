# -*- encoding : utf-8 -*-
Given %r(в игре "(.*)" следующие задания:$)i do |game_name, levels_table|
  game = Game.where(name: game_name).first
  author_name = game.author.nickname

  levels_table.hashes.each do |hash|
    level_name = hash['Название']
    code = hash['Код']
    step %{#{author_name} добавляет задание "#{level_name}" с кодом "#{code}" в игру "#{game_name}"}
  end
end

Given /добавляю задание "([^\"]*)" в игру "([^\"]*)"$/ do |level_name, game_name|
  step %{добавляю задание "#{level_name}" с кодом "enКраблеБумц" в игру "#{game_name}"}
end

Given /добавляю задание "([^\"]*)" с кодом "([^\"]*)" в игру "([^\"]*)"$/ do |level_name, code, game_name|
  step %{захожу в профиль игры "#{game_name}"}
  step %{иду по ссылке "Добавить новое задание"}
  step %{я ввожу "#{level_name}" в поле "Название"}
  step %{ввожу "#{level_name}" в поле "Текст задания"}
  step %{ввожу "#{code}" в поле "Код"}
  step %{нажимаю "Добавить задание"}
  step %{должен быть перенаправлен в профиль задания "#{level_name}"}
  step %{должен увидеть "#{level_name}"}
end

Given %r{^(.*) добавляет задание "([^\"]*)" в игру "(.*)"}i do |user_name, level_name, game_name|
  step %{я логинюсь как #{user_name}}
  step %{добавляю задание "#{level_name}" в игру "#{game_name}"}
end

Given %r{^(.+) добавляет задание "([^\"]*)" с кодом "([^\"]*)" в игру "([^\"]*)"$}i do |user_name, level_name, code, game_name|
  step %{я логинюсь как #{user_name}}
  step %{добавляю задание "#{level_name}" с кодом "#{code}" в игру "#{game_name}"}
end

Given /в игру "([^\"]*)" добавлено задание "([^\"]*)" с кодом "([^\"]*)"$/ do |game_name, level_name, code|
  game = Game.where(name: game_name).first
  author_name = game.author.nickname

  step %{я логинюсь как #{author_name}}
  step %{добавляю задание "#{level_name}" с кодом "#{code}" в игру "#{game_name}"}
end

Given /^в игру "([^\"]*)" добавлено задание "([^\"]*)" со следующими кодами:$/ do |game_name, level_name, table|
  game = Game.where(name: game_name).first
  author_name = game.author.nickname

  codes = table.raw.map(&:first)
  code_count = codes.size

  first_code = codes.shift
  step %{#{author_name} добавляет задание "#{level_name}" с кодом "#{first_code}" в игру "#{game_name}"}

  codes.each do |code|
    step %{#{author_name} добавляет код "#{code}" в задание "#{level_name}"}
  end

  # This step exists to build the #88 mechanic -- several markers at one
  # location, ALL of which must be found -- which is what every scenario using
  # it asserts. New levels now default to any_code_passes, so the old rule is
  # stated here rather than relied upon. See
  # docs/superpowers/specs/2026-08-06-redundant-codes-design.md §6.
  #
  # update_column because the surrounding scenario may already have moved the
  # clock past the game's start time, which makes the game fail its own
  # validations and any ordinary save raise.
  Level.where(:name => level_name).first.update_column(:any_code_passes, false)

  step %{я захожу в профиль задания "#{level_name}"}
  step %{должен увидеть "Коды (#{code_count})"}
end

Given /^([^\"]*) добавляет код "([^\"]*)" в задание "([^\"]*)"$/ do |author_name, code, level_name|
  step %{я захожу в профиль задания "#{level_name}"}
  step %{иду по ссылке "Добавить ещё один код"}
  step %{ввожу "#{code}" в поле "Код"}
  step %{нажимаю "Добавить"}
  step %{должен быть перенаправлен в профиль задания "#{level_name}"}
  step %{должен увидеть "#{code}"}
end

Given /^добавляю код "([^\"]*)" в задание "([^\"]*)"$/ do |code, level_name|
  author = Level.where(name: level_name).first.game.author.nickname
  step %{#{author} добавляет код "#{code}" в задание "#{level_name}"}
end

Given /^пользователем (.*) создана игра "(.*)" со следующими заданиями:$/ do |author_name, game_name, levels_table|
  step %{пользователем #{author_name} создана игра "#{game_name}"}

  levels = levels_table.raw.map(&:first)
  levels.each.each do |level_name|
    step %{в игру "#{game_name}" добавлено задание "#{level_name}" с кодом "крабле-крабле-бумц"}
  end
end

# resource(level.game, level) -> game_level_path(level.game, level)
When %r{захожу в профиль задания "(.*)"$}i do |level_name|
  level = Level.where(name: level_name).first
  step %{захожу по адресу #{game_level_path(level.game, level)}}
end

Then /должен быть перенаправлен в профиль задания "(.*)"/ do |level_name|
  level = Level.where(name: level_name).first
  assert_redirected_to_path game_level_path(level.game, level)
end
