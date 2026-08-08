# -*- encoding : utf-8 -*-
#
# Merb's `resource(game)` / `resource(game, level)` URL builder is replaced
# throughout by the Rails path helpers for the same routes:
#   resource(game)              -> game_path(game)          -> /games/1
#   resource(level.game, level) -> game_level_path(g, l)    -> /games/1/levels/2

Given /пользователем (.*) создана игра "(.*)"$/ do |user_name, game_name|
  step %{я зарегистрирован как #{user_name}}
  step %{#{user_name} создаёт игру "#{game_name}"}
end

Given /^создана игра "(.*)"$/ do |game_name|
  author_name = 'Author'
  step %{пользователем #{author_name} создана игра "#{game_name}"}
end

Given /(.*) создаёт игру "(.*)"$/ do |user_name, game_name|
  starts= Time.now + 7.days
  deadline= Time.now + 6.days
  step %{я логинюсь как #{user_name}}
  step %{я захожу в личный кабинет}
  step %{иду по ссылке "Создать игру"}
  step %{ввожу "#{game_name}" в поле "Название"}
  step %{ввожу "Описание #{game_name}" в поле "Описание"}
  step %{ввожу "2" в поле "Максимальное количество команд"}
  step %{ввожу "#{starts}" в поле "Начало игры"}
  step %{ввожу "#{deadline}" в поле "Крайний срок регистрации"}
  step %{нажимаю "Создать"}
  step %{должен быть перенаправлен в профиль игры "#{game_name}"}
end

Given %r{(.*) назначает начало игры "(.*)" на "(.*)"} do |user_name, game_name, datetime|
  step %{Я логинюсь как #{user_name}}
  step %{захожу в профиль игры "#{game_name}"}
  step %{иду по ссылке "Редактировать эту игру"}
  step %{ввожу "#{datetime}" в поле "Начало игры"}
  step %{нажимаю "Сохранить"}
  step %{должен быть перенаправлен в профиль игры "#{game_name}"}
  step %{должен увидеть "#{datetime}"}
  step %{я разлогиниваюсь}
end
Given %r{(.*) назначает крайний срок регистрации на игру "(.*)" на "(.*)"} do |user_name, game_name, datetime|
  step %{Я логинюсь как #{user_name}}
  step %{захожу в профиль игры "#{game_name}"}
  step %{иду по ссылке "Редактировать эту игру"}
  step %{ввожу "#{datetime}" в поле "Крайний срок регистрации"}
  step %{нажимаю "Сохранить"}
  step %{должен быть перенаправлен в профиль игры "#{game_name}"}
  step %{должен увидеть "#{datetime}"}
  step %{я разлогиниваюсь}
end

Given /начало игры "(.*)" назначено на "(.*)"/ do |game_name, datetime|
  game = Game.where(name: game_name).first
  author_name = game.author.nickname
  step %{#{author_name} назначает начало игры "#{game_name}" на "#{datetime}"}
end
Given /крайний срок регистрации игры "(.*)" назначено на "(.*)"/ do |game_name, datetime|
  game = Game.where(name: game_name).first
  author_name = game.author.nickname
  step %{#{author_name} назначает крайний срок регистрации на игру "#{game_name}" на "#{datetime}"}
end

When %r{захожу в профиль игры "(.*)"$}i do |game_name|
  game = Game.where(name: game_name).first
  step %{захожу по адресу #{game_path(game)}}
end

When /захожу в список игр$/ do
  step %{я захожу на главную страницу}
  step %{иду по ссылке "Список игр"}
end

Then %r{должен быть перенаправлен в профиль игры "(.*)"$}i do |game_name|
  game = Game.where(name: game_name).first
  assert_redirected_to_path game_path(game)
end

Given /^(.*) добавил задание "([^\"]*)" в игру "([^\"]*)"$/ do |author_name, level_name, game_name|
  game = Game.where(name: game_name).first
  step %{я логинюсь как #{author_name}}
  step %{добавляю задание "#{level_name}" в игру "#{game_name}"}
end

Given /^в игре "([^\"]*)" нет заданий$/ do |game_name|
  # Это пустышка. Нужна чтобы сценарий читался логично.
end

Given /^игра "([^\"]*)" не черновик$/ do |game_name|
  game = Game.where(name: game_name).first
  author_name = game.author.nickname
  step %{я логинюсь как #{author_name}}
  step %{захожу в профиль игры "#{game_name}"}
  step %{иду по ссылке "Редактировать эту игру"}
  step %{снимаю галочку "Черновик"}
  step %{нажимаю "Сохранить"}
  step %{не должен видеть "Черновик"}
end

Given /^игра "([^\"]*)" черновик$/ do |game_name|
  game = Game.where(name: game_name).first
  author_name = game.author.nickname
  step %{я логинюсь как #{author_name}}
  step %{захожу в профиль игры "#{game_name}"}
  step %{иду по ссылке "Редактировать эту игру"}
  step %{отмечаю галочку "Черновик"}
  step %{нажимаю "Сохранить"}
end

Given /^есть пользователь "([^\"]*)"$/ do |user_name|
  step %{я залогинен как #{user_name}}
  step %{должен увидеть "#{user_name}"}
end

Given /^пользователь "([^\"]*)" создал команду "([^\"]*)"$/ do |user_name, team_name|
  step %{зарегистрирована команда "#{team_name}" под руководством (#{user_name})}
end

Given /^пользователь "([^\"]*)" является членом команды "([^\"]*)"$/ do |user_name, team_name|
  step %{пользователь #{user_name} состоит в команде "#{team_name}"}
end

Given /^я залогинён как "([^\"]*)"$/ do |user_name|
  step %{я логинюсь как #{user_name}}
end

Given /^игра "([^\"]*)" не начата$/ do |game_name|
  game=Game.where(name: game_name).first
  game.starts_at=Time.now+3.days
  game.registration_deadline = Time.now+2.days
  game.save
end

Given /^игра "([^\"]*)" уже начата$/ do |game_name|
  game=Game.where(name: game_name).first
  step %{сейчас "#{game.starts_at+1.hour}"}

end

When /^я нахожусь на странице "([^\"]*)"$/ do |page|
  page = "личный кабинет" if page == "Личный кабинет"
  page = "комнату команды" if page == "Комната команды"
  step %{захожу в #{page}}
end

Given /^не должен видеть ссылку "([^\"]*)"$/ do |link|
  step %{не должен видеть ссылку на #{link}$}
end

Given /^должен видеть ссылку "([^\"]*)"$/ do |link|
  step %{должен видеть ссылку на #{link}$}
end

# Was an empty no-op; see the near-twin step "я обновляю страницу" in
# features/game-passing/steps/game-passing_steps.rb, which stays a plain GET
# reload for reasons explained there. This step delegates to reload_last_page
# (features/support/env.rb), which reproduces a real browser reload's
# resubmit-on-non-GET behaviour -- see the comment there for why a bare
# `visit page.current_url` is not enough.
Given /^страница перегружается$/ do
  reload_last_page
end

When /^нажимаю на "([^\"]*)"$/ do |link|
  step %{нажимаю #{link}$}
end

Given /^капитан "([^\"]*)" зарегистрировал свою команду на участие в игре "([^\"]*)"$/ do |team_leader, game_name|
  game = Game.where(name: game_name).first
  author_name = game.author.nickname
  step %{капитан #{team_leader} подал заявку на участие в игре}
  step %{я разлогиниваюсь}
  step %{я логинюсь как #{author_name}}
  step %{захожу в личный кабинет}
  step %{иду по ссылке "(принять)"}
  step %{я разлогиниваюсь}
end

Given /^капитан "([^\"]*)" не зарегистрировал свою команду на участие в игре "([^\"]*)"$/ do |team_leader, game_name|
  game = Game.where(name: game_name).first
  author_name = game.author.nickname
  step %{капитан #{team_leader} подал заявку на участие в игре}
  step %{я разлогиниваюсь}
  step %{я логинюсь как #{author_name}}
  step %{захожу в личный кабинет}
  step %{иду по ссылке "(отказать)"}
  step %{я разлогиниваюсь}
end

Given /^автор "([^\"]*)" отказал команде на участие в игре$/ do |author_name|
  step %{я логинюсь как #{author_name}}
  step %{захожу в личный кабинет}
  step %{иду по ссылке "(отказать)"}
  step %{я разлогиниваюсь}
end

Given /^капитан (.*) подал заявку на участие в игре$/ do |team_leader|
  step %{я логинюсь как #{team_leader}}
  step %{захожу в личный кабинет}
  step %{иду по ссылке "Подать заявку на регистрацию"}
end

Given /^команда ([^\s]+) подала заявку на участие в игре "(.*)"$/ do |team_name, game_name|
  step %{зарегистрирована команда "#{team_name}" под руководством team-leader}
  step %{я логинюсь как team-leader}
  step %{захожу в личный кабинет}
  step %{иду по ссылке "Подать заявку на регистрацию"}
end

Given /^есть задание "([^\"]*)" в игре "([^\"]*)"$/ do |level_name, game_name|
  game = Game.where(name: game_name).first
  author_name = game.author.nickname
  step %{#{author_name} добавляет задание "#{level_name}" в игру "#{game_name}"}
end

Given /^команда "(.*)" под руководством "(.*)" подала заявку на участие в игре "(.*)"$/ do |team_name, captain_name, game_name|
  step %{я логинюсь как #{captain_name}}
  step %{я захожу в комнату команды}
  step %{иду по ссылке "Подать заявку на регистрацию"}
end
Given /^(.*) подтвердил участие команды "(.*)" в игре "(.*)"$/ do |author_name, team_name, game_name|
  step %{я залогинился как автор игры "#{game_name}"}
  step %{захожу в личный кабинет}
  step %{иду по ссылке "(принять)"}
end

Given /^я залогинился как автор игры "(.*)"$/ do |game_name|
  game = Game.where(name: game_name).first
  author = User.find(game.author_id)
  step %{я логинюсь как #{author.nickname}}
end

Given /^команда "([^\"]*)" отозвала заявку на участие в игре$/ do |team_name|
  team = Team.where(name: team_name).first
  captain_name = team.captain.nickname
  step %{я логинюсь как #{captain_name}}
  step %{захожу в личный кабинет}
  step %{иду по ссылке "Отозвать"}
end
Given /([^\s]+) создал игру "([^\"]*)" с началом в "([^\"]*)" и с крайним сроком регистрации в "([^\"]*)"$/ do |author_name, game_name, starts_at, deadline_at|
  step %{я зарегистрирован как #{author_name}}
  step %{я захожу в личный кабинет}
  step %{иду по ссылке "Создать игру"}
  step %{ввожу "#{game_name}" в поле "Название"}
  step %{ввожу "Описание #{game_name}" в поле "Описание"}
  step %{ввожу "#{starts_at}" в поле "Начало игры"}
  step %{ввожу "#{deadline_at}" в поле "Крайний срок регистрации"}
  step %{ввожу "6" в поле "Максимальное количество команд"}
  step %{нажимаю "Создать"}
  step %{должен быть перенаправлен в профиль игры "#{game_name}"}
end

Given /^команда "([^\"]*)" отменила регистрацию в игре$/ do |team_name|
  team = Team.where(name: team_name).first
  captain_name = team.captain.nickname
  step %{я логинюсь как #{captain_name}}
  step %{захожу в личный кабинет}
  step %{иду по ссылке "Отменить"}
end

Given /^задано максимальное количество команд "([^\"]*)" для игры "([^\"]*)"$/ do |max_num, game_name|
  step %{я залогинился как автор игры "#{game_name}"}
  step %{захожу в профиль игры "#{game_name}"}
  step %{иду по ссылке "Редактировать эту игру"}
  step %{ввожу "#{max_num}" в поле "Максимальное количество команд"}
  step %{нажимаю "Сохранить"}
end

# Webrat's field_labeled(...) returned a Webrat::PasswordField / ::TextField
# wrapper and the step matched /password/i against the class name. Capybara
# returns the element itself, so read the input's type attribute -- which is
# what the class name stood for.
When /поле "(.*)" имеет тип "(.*)"$/ do |field, type|
  expect(find_field(field)[:type].to_s).to match(/#{type}/i)
end

Given /^игра завершена автором "(.*)"$/ do |author_name|
  step %{я логинюсь как #{author_name}}
  step %{захожу в личный кабинет}
  step %{иду по ссылке "ЗАВЕРШИТЬ ИГРУ"}
  step %{я разлогиниваюсь}
end

# `:all` for the same reason as features/steps/result_steps.rb -- see the note
# there.
Then /должен в блоке "([^"]+)" увидеть "([^"]+)"$/ do |block_id, text|
  within("##{block_id}") { expect(page).to have_text(:all, text) }
end

Then /не должен в блоке "([^"]+)" видеть "([^"]+)"$/ do |block_id, text|
  within("##{block_id}") { expect(page).to have_no_text(:all, text) }
end

Given %r{зарегистрирован определенный пользователь: "([^"]+)", "([^"]+)", "([^"]+)"$}i do |nickname, e_mail, password|
  step %{я пытаюсь зарегистрироваться с данными "#{nickname}", "#{e_mail}", "#{password}"}
  step %{То я должен быть перенаправлен в личный кабинет}
  step %{должен увидеть "#{nickname}"}
  step %{я разлогиниваюсь}
  step %{все отосланные к этому моменту письма прочитаны}
end

When %r{пытаюсь зарегистрироваться с данными "([^"]+)", "([^"]+)", "([^"]+)"}i do |nickname, e_mail, password|
  step %{я захожу по адресу /signup}
  step %{я ввожу "#{nickname}" в поле "Имя"}
  step %{ввожу "#{e_mail}" в поле "Email"}
  step %{нажимаю "Зарегистрироваться"}

  # Signup no longer collects a password -- the server generates one (2026-08-08
  # product decision). These scenarios name the password they will later log in
  # with, so set it through the model, the only path that does not demand the
  # current password. Guarded: this step is also driven with a duplicate
  # address, where no account is created and none should be touched.
  user = User.find_by(:email => e_mail)
  user.update!(:password => password, :password_confirmation => password) if user
end

Then /^данные пользователя "([^"]+)" с паролем "([^"]+)" такие "([^"]+)"$/ do |nickname, password, date_of_birth|
  step %{залогинился как "#{nickname}" с паролем "#{password}"}
  step %{иду по ссылке "Профиль"}
  step %{иду по ссылке "Редактировать профиль..."}
  step %{ввожу "#{date_of_birth}" в поле "Дата рождения"}
  step %{нажимаю "Принять изменения"}
  step %{иду по ссылке "Выйти"}
end

Then /^данные капитана "([^"]+)" с паролем "([^"]+)" такие "([^"]+)", "([^"]+)"$/ do |nickname, password, date_of_birth, phone_number|
  step %{залогинился как "#{nickname}" с паролем "#{password}"}
  step %{иду по ссылке "Профиль"}
  step %{иду по ссылке "Редактировать профиль..."}
  step %{ввожу "#{date_of_birth}" в поле "Дата рождения"}
  step %{ввожу "#{phone_number}" в поле "Контактный телефон"}
  step %{нажимаю "Принять изменения"}
  step %{иду по ссылке "Выйти"}
end


When %r{залогинился как "([^"]+)" с паролем "([^"]+)"$} do |nickname, password|
  email = User.where(nickname: nickname).first.email

  step %{я захожу по адресу /login}
  step %{ввожу "#{email}" в поле "Email"}
  step %{ввожу "#{password}" в поле "Пароль"}
  step %{нажимаю "Войти"}
  step %{должен быть перенаправлен в личный кабинет}
  step %{должен увидеть "#{nickname}"}
end

Given %r{игрок "([^"]+)" с паролем "([^"]+)" создает команду "([^"]+)"}i do |nickname, password, team_name|
  step %{залогинился как "#{nickname}" с паролем "#{password}"}
  step %{я пытаюсь создать команду "#{team_name}"}
  step %{должен быть перенаправлен в личный кабинет}
  step %{там должен увидеть "Вы - капитан команды"}
  step %{должен увидеть "#{team_name}"}
end

When /^пароль пользователя "([^"]*)" равен "([^"]*)"$/ do |nickname, password|
  step %{залогинился как "#{nickname}" с паролем "#{password}"}
end

When /^команда "([^\"]*)" завершает игру "([^\"]*)"$/ do |team_name, game_name|
  last_level = Game.where(name: game_name).first.levels.last

  step %{команда #{team_name} находится на уровне "#{last_level.name}" игры "#{game_name}"}
  step %{команда #{team_name} вводит правильные коды последнего уровня игры "#{game_name}"}
end

When /команда (.*) вводит правильные коды последнего уровня игры "(.*)"/ do |team_name, game_name|
  team = Team.where(name: team_name).first
  game = Game.where(name: game_name).first
  current_level = game.levels.last

  step %{я логинюсь как #{team.captain.nickname}}
  current_level.questions.each do |question|
    step %{ввожу код "#{question.answers.first.value}" в игре "#{game_name}"}
  end
  step %{должен увидеть "Поздравляем"}
end

Given %r{(.*) завершил тестирование игры "(.*)"} do |author_name, game_name|
  step %{я логинюсь как #{author_name}}
  step %{захожу в личный кабинет}
  step %{должен увидеть "#{game_name}"}
  step %{захожу в профиль игры "#{game_name}"}
  step %{я иду по ссылке "Начать тестирование"}
  step %{я иду по ссылке "Старт"}
  step %{я ввожу "1234" в поле "Код"}
  step %{и нажимаю "Отправить!"}
  step %{я ввожу "1234" в поле "Код"}
  step %{и нажимаю "Отправить!"}
  step %{я иду по ссылке "Завершить тестирование"}
  step %{игра "#{game_name}" не черновик}
  step %{я разлогиниваюсь}
end
