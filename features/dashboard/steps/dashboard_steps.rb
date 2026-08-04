# -*- encoding : utf-8 -*-
When %r{захожу в личный кабинет}i do
  step %{захожу по адресу /dashboard}
end

Then %r{должен быть перенаправлен в личный кабинет$} do
  step %{должен быть перенаправлен по адресу /dashboard}
end
