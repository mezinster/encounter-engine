# -*- encoding : utf-8 -*-
Given %r(на уровне "(.*)" следующие подсказки:$)i do |level_name, hints_table|
  level = Level.where(name: level_name).first
  author_name = level.game.author.nickname

  hints_table.hashes.each do |hash|
    text = hash['Текст']
    delay = hash['Через'].match(/(\d+) минут.?/)[1]
    step %{#{author_name} добавила подсказку "#{text}" через #{delay} минут на уровне "#{level_name}"}
  end
end

Given %r((.*) добавила? подсказку "(.*)" через (\d+) минут на уровне "(.*)")i do |author_name, hint_text, hint_delay, level_name|
  step %{я логинюсь как #{author_name}}
  step %{захожу в профиль задания "#{level_name}"}
  step %{я иду по ссылке "Добавить подсказку"}
  step %{ввожу "#{hint_text}" в поле "Текст"}
  step %{ввожу "#{hint_delay}" в поле "Через"}
  step %{нажимаю "Добавить"}
  step %{должен быть перенаправлен в профиль задания "#{level_name}"}
  step %{должен увидеть "#{hint_text}"}
  step %{должен увидеть "#{hint_delay}"}
end
