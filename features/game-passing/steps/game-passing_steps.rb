# -*- encoding : utf-8 -*-

# Webrat shipped a `tableish` helper that scraped a DOM table into an array of
# arrays for DataTable#diff!. Capybara has no equivalent, so here it is: same
# signature (row selector, cell selector), same return shape.
def tableish(row_selector, column_selector)
  page.all(row_selector).map do |row|
    row.all(column_selector).map { |cell| cell.text.strip }
  end
end

Given /команда (.*) находится на уровне "(.*)" игры "(.*)"/ do |team_name, level_name, game_name|
  team = Team.where(name: team_name).first
  game = Game.where(name: game_name).first

  step %{я логинюсь как #{team.captain.nickname}}
  step %{захожу в игру "#{game_name}"}

  current_level = team.current_level_in(game)
  current_position = current_level.nil? ? 1 : current_level.position

  target_level = game.levels.where(name: level_name).first
  target_position = target_level.position

  level_count_to_pass = target_position - current_position
  level_count_to_pass.times do
    step %{команда #{team_name} вводит правильный код текущего уровня игры "#{game_name}"}
  end
end

Given /команда (.*) закончила игру "(.*)"/ do |team_name, game_name|
  last_level = Game.where(name: game_name).first.levels.last

  step %{команда #{team_name} находится на уровне "#{last_level.name}" игры "#{game_name}"}
  step %{команда #{team_name} вводит правильный код последнего уровня игры "#{game_name}"}
end

When /ввожу код "([^\"]*)"$/ do |code|
  step %{я ввожу "#{code}" в поле "Код"}
  step %{нажимаю "Отправить!"}
end

When /ввожу код "([^\"]*)" в игре "([^\"]*)"/ do |code, game_name|
  step %{захожу в игру "#{game_name}"}
  step %{ввожу код "#{code}"}
end

When /команда (.*) вводит правильный код текущего уровня игры "(.*)"/ do |team_name, game_name|
  team = Team.where(name: team_name).first
  game = Game.where(name: game_name).first
  current_level = team.current_level_in(game) || game.levels.first

  step %{я логинюсь как #{team.captain.nickname}}
  step %{ввожу код "#{current_level.questions.first.answers.first.value}" в игре "#{game_name}"}
  step %{должен увидеть "#{current_level.next.name}"}
end

When /команда (.*) вводит правильный код последнего уровня игры "(.*)"/ do |team_name, game_name|
  team = Team.where(name: team_name).first
  game = Game.where(name: game_name).first
  current_level = game.levels.last

  step %{я логинюсь как #{team.captain.nickname}}
  step %{ввожу код "#{current_level.questions.first.answers.first.value}" в игре "#{game_name}"}
  step %{должен увидеть "Поздравляем"}
end

When /захожу в игру "([^\"]*)"/ do |game_name|
  game = Game.where(name: game_name).first

  step %{я захожу в личный кабинет}

  within "#game-#{game.id}" do
    click_link "Играть!"
  end
end

Then /список победителей должен быть следующим:$/ do |expected_results_table|
  expected_results_table.diff!(tableish('#results tr', 'td,th'), :missing_col => false)
end

Then /должен увидеть следующие позиции команд:$/ do |expected_stats_table|
  expected_stats_table.diff!(tableish('table#stats tr', 'td,th'))
end

When /захожу в статистику игры "(.*)"$/ do |game_name|
  step %{захожу в личный кабинет}
  step %{должен увидеть "#{game_name}"}
  step %{иду по ссылке "(статистика)"}
end

Given /в "(.*)" команда "(.*)" на задании "(.*)" игры "(.*)" ввела код "(.*)"$/ do |datetime, team_name, level_name, game_name, code|
  team = Team.where(name: team_name).first

  step %{сейчас "#{datetime}"}
  step %{я логинюсь как #{team.captain.nickname}}
  step %{команда #{team_name} находится на уровне "#{level_name}" игры "#{game_name}"}
  step %{ввожу код "#{code}"}
end

Given /^команда (.*) сошла с дистанции игры "([^"]*)"$/ do |team_name, game_name|
  team = Team.where(name: team_name).first

  step %{я логинюсь как #{team.captain.nickname}}
  step %{я захожу в игру "#{game_name}"}
  step %{ иду по ссылке "Сойти с дистанции"}
end

Then /должен увидеть следующюю таблицу:/ do |strings_table|
  strings_table.diff!(tableish('#results tr', 'td,th'), :missing_col => false)
end

Given /^я обновляю страницу$/ do

end
