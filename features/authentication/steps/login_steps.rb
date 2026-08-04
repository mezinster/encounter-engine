# -*- encoding : utf-8 -*-
Given %r{разлогиниваюсь$}i do
  step %{захожу по адресу /logout}
end

Given %r{не залогинен$}i do
  step %{я разлогиниваюсь}
end

Given %r{залогинен как (.*)$}i do |nickname|
  step %{я разлогиниваюсь}
  step %{я пытаюсь зарегистрироваться как #{nickname}}
  step %{То я должен быть перенаправлен в личный кабинет}
  step %{должен увидеть "#{nickname}"}
  step %{все отосланные к этому моменту письма прочитаны}
end

Given %r{зарегистрирован как (.*)$}i do |nickname|
  step %{я залогинен как #{nickname}}
end

When %r{логинюсь как (.*)$} do |nickname|
  email = "#{nickname.downcase}@diesel.kg"

  step %{я захожу по адресу /login}
  step %{ввожу "#{email}" в поле "Email"}
  step %{ввожу "#{@the_password}" в поле "Пароль"}
  step %{нажимаю "Войти"}
  step %{должен быть перенаправлен в личный кабинет}
  step %{должен увидеть "#{nickname}"}
end

Then %r{не должен быть залогинен$}i do
  step %{я захожу по адресу /dashboard}
  step %{должен увидеть "Вы не авторизованы для посещения этой страницы. Попробуйте выполнить вход"}
end
