# -*- encoding : utf-8 -*-
When %r{захожу на главную страницу$}i do
  step %{захожу по адресу /}
end

Then %r{должен быть перенаправлен на главную страницу}i do
  assert_redirected_to_path root_path
end
