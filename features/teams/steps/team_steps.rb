# -*- encoding : utf-8 -*-
Given %r{зарегистрирована команда "(.*)" под руководством (.*)}i do |team_name, nickname|
  step %{я залогинен как #{nickname}}
  step %{я пытаюсь создать команду "#{team_name}"}
  step %{должен быть перенаправлен в личный кабинет}
  step %{там должен увидеть "Вы - капитан команды"}
  step %{должен увидеть "#{team_name}"}
end

When %r{пытаюсь создать команду "(.*)"}i do |team_name|
  step %{захожу в личный кабинет}
  step %{я иду по ссылке "Создать команду"}
  step %{ввожу "#{team_name}" в поле "Название"}
  step %{нажимаю "Создать команду"}
end

Given %r{пользователь (.*) состоит в команде "(.*)"}i do |nickname, team_name|
  captain_nickname = Team.where(name: team_name).first.captain.nickname

  # "пользователь X состоит в команде Y" states a precondition, so registering
  # X is only part of establishing it -- and only when X does not exist yet.
  # features/game-passing/throw_in_the_towel.feature:33-34 says "Допустим я
  # залогинен как Дастан / И пользователь Дастан состоит в команде ESDP11":
  # signing Дастан up a second time just fails validation and leaves the
  # browser on the re-rendered signup form. Nobody noticed because "должен быть
  # перенаправлен по адресу" used to assert nothing (see
  # features/steps/result_steps.rb).
  step %{зарегистрирован пользователь #{nickname}} unless User.exists?(nickname: nickname)
  step %{я логинюсь как #{captain_nickname}}
  step %{высылаю пользователю #{nickname} приглашение вступить в команду}
  step %{я логинюсь как #{nickname}}
  step %{я иду по ссылке "(принять)"}
  step %{должен быть перенаправлен в личный кабинет}
  step %{должен увидеть "Вы состоите в команде"}
  step %{должен увидеть "#{team_name}"}
end

Given %r{пользователь (.*) создает команду "(.*)"}i do |user_name, team_name|
  step %{я логинюсь как #{user_name}}
  step %{я пытаюсь создать команду "#{team_name}"}
  step %{должен быть перенаправлен в личный кабинет}
  step %{там должен увидеть "Вы - капитан команды"}
  step %{должен увидеть "#{team_name}"}
end
