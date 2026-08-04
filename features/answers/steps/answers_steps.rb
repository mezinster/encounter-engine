# -*- encoding : utf-8 -*-
Given /^я должен быть перенаправлен на страницу редактирования кода "([^\"]*)"$/ do |code|
  # do nothing
end

Given /^добавляю вариант "([^\"]*)" для кода "([^\"]*)"$/ do |variant, code|
  step %{захожу на страницу редактирования кода "#{code}"}
  step %{ввожу "#{variant}" в поле "Ещё один вариант кода"}
  step %{нажимаю "Добавить вариант кода"}
end

Given /^нажимаю на "([^\"]*)" возле варианта "([^\"]*)"$/ do |button_name, code|
  answer = Answer.where(value: code).first
  # Webrat's within yielded a scope object; Capybara's runs the block with the
  # scope already applied, so the bare helper is the scoped one.
  within "#answer-#{answer.id}" do
    click_link button_name
  end
end

Given /^захожу на страницу редактирования кода "([^\"]*)"$/ do |code|
  answer = Answer.where(value: code).first

  step %{я захожу в профиль задания "#{answer.level.name}"}
  within "#question-#{answer.question.id}" do
    click_link "(редактировать)"
  end
end

Given /^для уровня "([^\"]*)" есть следующие коды:$/ do |level_name, codes|
  step %{я захожу в профиль задания "#{level_name}"}

  codes.hashes.each do |hash|
    code = Answer.where(value: hash['Вариант_1']).first
    if code
      step %{добавляю вариант "#{hash['Вариант_2']}" для кода "#{hash['Вариант_1']}"}
    else
      step %{добавляю код "#{hash['Вариант_1']}" в задание "#{level_name}"}
      step %{добавляю вариант "#{hash['Вариант_2']}" для кода "#{hash['Вариант_1']}"}
    end
  end
end
