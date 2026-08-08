# -*- encoding : utf-8 -*-
Given %r{зарегистрирован пользователь (.*)$}i do |nickname|
  step %{я пытаюсь зарегистрироваться как #{nickname}}
  step %{То я должен быть перенаправлен в личный кабинет}
  step %{должен увидеть "#{nickname}"}
  step %{аккаунт "#{nickname}" получает тестовый пароль}
  step %{я разлогиниваюсь}
  step %{все отосланные к этому моменту письма прочитаны}
end

# Signup generates the first password server-side (2026-08-08 product
# decision), so the suite cannot know it -- but @the_password
# (features/steps/before_steps.rb) is what every later login step types. Reset
# the freshly created account to it through the model, which is the only place
# that can: UsersController#update demands the current password, and nobody
# here knows it.
#
# Deliberately NOT folded into "пытаюсь зарегистрироваться как": that step is
# also used by the duplicate-registration scenario, where the account already
# exists and must be left alone.
Given %r{аккаунт "(.*)" получает тестовый пароль$}i do |nickname|
  user = User.find_by(:email => "#{nickname.downcase}@diesel.kg")
  raise "no account registered for #{nickname}" if user.nil?

  user.update!(:password => @the_password, :password_confirmation => @the_password)
end

When %r{пытаюсь зарегистрироваться как (.*)}i do |nickname|
  email = "#{nickname.downcase}@diesel.kg"

  # No password/password_confirmation fill: signup no longer collects a
  # password (product decision 2026-08-08, see CLAUDE.md, "The
  # acceptance-suite rule", third authorised exception) -- the fields are
  # gone from app/views/users/new.html.erb, and the server generates the
  # first password instead.
  step %{я захожу по адресу /signup}
  step %{я ввожу "#{nickname}" в поле "Имя"}
  step %{ввожу "#{email}" в поле "Email"}
  step %{нажимаю "Зарегистрироваться"}
end
