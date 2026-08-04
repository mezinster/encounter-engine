# -*- encoding : utf-8 -*-
# Deliberately minimal. Task 8 (Controllers) owns the full version of this
# file per the migration plan -- `include Authentication`,
# `include LocaleSelection`, the Unauthenticated/Unauthorized rescue_from
# handlers, and the current_user/logged_in? helper_method declarations all
# land there. This stub exists only because SessionsController (Task 6) has
# to inherit from *something*, and Rails has no ApplicationController until
# some file defines it -- without this, the sessions_controller_spec.rb gate
# fails at boot with "uninitialized constant ApplicationController" before a
# single example runs.
class ApplicationController < ActionController::Base
end
