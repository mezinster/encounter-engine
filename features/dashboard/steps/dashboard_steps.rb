# -*- encoding : utf-8 -*-
When %r{захожу в личный кабинет}i do
  step %{захожу по адресу /dashboard}
end

Then %r{должен быть перенаправлен в личный кабинет$} do
  # Asserts for real (1,644 executions per suite run). It does not route
  # through the "должен быть перенаправлен по адресу" step, which stays a no-op
  # for its five direct feature-file callers -- see features/steps/result_steps.rb.
  assert_redirected_to_path dashboard_path
end
