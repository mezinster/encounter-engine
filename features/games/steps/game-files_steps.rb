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

# Game#status == :running, reached directly rather than through the existing
# `игра "X" уже начата` step: that one travels the clock (`сейчас "..."`),
# which these scenarios do not otherwise need, and it leaves visibility alone --
# a draft reports :draft from #status whatever the clock says (see Game#started?).
#
# The assertion at the end is not decoration. The typed-confirmation branch
# hangs off this one value, so a step that silently produced :draft or
# :scheduled would leave the two scenarios below passing while testing the
# ordinary, unconfirmed delete path.
Given /^игра "([^\"]*)" идёт$/ do |game_name|
  game = Game.where(:name => game_name).first
  game.update_column(:visibility, "listed")
  run = game.runs.reload.to_a.last || game.runs.create!(:ordinal => 1)
  run.update_column(:starts_at, 1.hour.ago)

  actual = game.reload.status
  raise "игра «#{game_name}» в состоянии #{actual}, а не :running" unless actual == :running
end

# Drives the real form, which is the only way this button is proved to work at
# all: the app has no Turbo and no rails-ujs, so the DELETE comes solely from
# the hidden _method field _file_table emits. Mutating that partial to
# `method: :post` left every spec and scenario green while a real author
# clicking Удалить got a routing error -- these two steps are what closes that.
#
# Scoped to the row's own form by its action, not by clicking the first
# "Удалить" on the page: every file renders one.
When /^удаляю файл "([^\"]*)"$/ do |filename|
  file = GameFile.where(:filename => filename).first
  within("form[action='#{game_game_file_path(file.game, file)}']") do
    click_button(I18n.t("game_files.index.delete"))
  end
end

# The same form, plus the confirmation a RUNNING game demands. Deliberately a
# separate step rather than an optional tail on the one above: the two anchored
# regexes cannot both match one line, so neither scenario can bind to the wrong
# definition and quietly test the other path.
When /^удаляю файл "([^\"]*)", подтверждая именем "([^\"]*)"$/ do |filename, typed_name|
  file = GameFile.where(:filename => filename).first
  within("form[action='#{game_game_file_path(file.game, file)}']") do
    fill_in("confirm_filename_#{file.id}", :with => typed_name)
    click_button(I18n.t("game_files.index.delete"))
  end
end
