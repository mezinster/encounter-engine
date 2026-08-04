# -*- encoding : utf-8 -*-
When /захожу в прямой эфир игры "(.*)"$/ do |game_name|
  game = Game.where(name: game_name).first
  step %{иду по ссылке "Все игры домена"}
  step %{должен увидеть "#{game_name}"}
  step %{должен увидеть "(прямой эфир)"}
  step %{иду по ссылке "(прямой эфир)"}
end

Given /захожу в лог ответов команды "(.*)" по игре "(.*)"$/ do |team_name, game_name|
  game_id = Game.where(name: game_name).first.id
  team_id = Team.where(name: team_name).first.id

  step %{захожу по адресу /logs/level/#{game_id}/#{team_id}}
end

When /смотрю полный лог ответов по игре "(.*)"$/ do |game_name|
  step %{захожу в личный кабинет}
  step %{должен увидеть "#{game_name}"}
  step %{иду по ссылке "(лог ответов)"}
end
