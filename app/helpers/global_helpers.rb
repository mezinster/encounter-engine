# -*- encoding : utf-8 -*-
# Not part of Task 8's scope (Task 9 owns app/helpers' actual content), but
# `module Merb; module GlobalHelpers; end; end` blocked `bin/rails
# zeitwerk:check` -- Zeitwerk expects a file at app/helpers/global_helpers.rb
# to define top-level GlobalHelpers, not Merb::GlobalHelpers. Fixed the
# nesting only; the module is still empty, exactly as it was under Merb.
module GlobalHelpers
  # helpers defined here available to all views.
end
