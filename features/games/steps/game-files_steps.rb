# -*- encoding : utf-8 -*-
Given /^максимальный размер файла равен (\d+) МБ$/ do |megabytes|
  Setting.put("file_max_megabytes", megabytes.to_i)
end

When /^иду в файлы игры "([^\"]*)"$/ do |game_name|
  visit game_game_files_path(Game.where(:name => game_name).first)
end

When /^загружаю файл "([^\"]*)"$/ do |filename|
  attach_file("files[]", Rails.root.join("spec/fixtures/files", filename))
  click_button(I18n.t("game_files.index.upload"))
end

When /^прикрепляю файл "([^\"]*)" к уровню "([^\"]*)"$/ do |filename, level_name|
  file = GameFile.where(:filename => filename).first
  level = Level.where(:name => level_name).first
  FileAttachment.create!(:game_file => file, :attachable => level)
end
