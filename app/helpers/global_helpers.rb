# -*- encoding : utf-8 -*-
# Not part of Task 8's scope (Task 9 owns app/helpers' actual content), but
# `module Merb; module GlobalHelpers; end; end` blocked `bin/rails
# zeitwerk:check` -- Zeitwerk expects a file at app/helpers/global_helpers.rb
# to define top-level GlobalHelpers, not Merb::GlobalHelpers. Fixed the
# nesting only; the module is still empty, exactly as it was under Merb.
module GlobalHelpers
  # helpers defined here available to all views.

  # Ports merb-helpers' Errorifier#error_messages_for
  # (vendor/merb/merb-helpers/lib/merb-helpers/form/builder.rb:403-416) and
  # its default options from the top-level wrapper
  # (vendor/merb/merb-helpers/lib/merb-helpers/form/helpers.rb:435-441).
  # Rails' `errors.full_messages` is composed the same way the Merb original
  # relied on (humanized attribute + message), so the rendered text is
  # unchanged -- only the framework wiring is new.
  #
  # Call sites match the Merb originals verbatim, e.g.:
  #   error_messages_for @user
  #   error_messages_for @user, header: "<h2>Ошибка</h2>"
  #
  # Before (Merb, vendor/merb/merb-helpers/.../builder.rb:404-416):
  #   header_message = header % [errors.size, errors.size == 1 ? "" : "s"]
  #   markup = "<div class='#{error_class}'>#{header_message}<ul>"
  #   errors.full_messages.each { |err| markup << (build_li % err) }
  #   markup << "</ul></div>"
  def error_messages_for(obj, options = {})
    return "".html_safe unless obj.respond_to?(:errors)

    errors = obj.errors
    return "".html_safe if errors.empty?

    error_class = options[:error_class] || "error"
    build_li    = options[:build_li]    || "<li>%s</li>"
    header      = options[:header]      || "<h2>Form submission failed because of %s problem%s</h2>"

    header_message = header % [errors.size, errors.size == 1 ? "" : "s"]

    markup = +"<div class='#{error_class}'>#{header_message}<ul>"
    errors.full_messages.each { |message| markup << (build_li % message) }
    markup << "</ul></div>"

    markup.html_safe
  end
end
