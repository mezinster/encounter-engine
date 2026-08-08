# -*- encoding : utf-8 -*-
require "rails_helper"

# Pins two escaping properties of ApplicationHelper#error_messages_for that
# spec/requests/error_messages_escaping_spec.rb doesn't reach:
#
# 1. Escaping a full_message has to be unconditional. ERB::Util.html_escape
#    is a no-op on a string that already answers true to html_safe? -- and a
#    full_message can be html_safe today via an `_html`-suffixed i18n key
#    (Rails marks those safe automatically), which is exactly the path a
#    future validation message is likely to take to interpolate a persisted
#    value. CGI.escapeHTML escapes regardless of the safe flag.
# 2. error_class (options[:error_class]) is also a caller-controlled value,
#    not part of the developer-supplied format string, so it gets escaped
#    too.
describe ApplicationHelper, :type => :helper do
  def object_with_errors(full_messages)
    errors = double(:empty? => false, :size => full_messages.size, :full_messages => full_messages)
    double(:errors => errors)
  end

  describe "#error_messages_for" do
    it "escapes a full_message even when it is already marked html_safe" do
      hostile = "safe <b>y</b>".html_safe
      obj = object_with_errors([hostile])

      markup = helper.error_messages_for(obj)

      expect(markup).not_to include("<b>y</b>")
      expect(markup).to include(CGI.escapeHTML("safe <b>y</b>"))
    end

    it "escapes a hostile error_class option" do
      obj = object_with_errors(["a message"])

      markup = helper.error_messages_for(obj, :error_class => "\"><script>alert(1)</script>")

      expect(markup).not_to include("<script>alert(1)</script>")
      expect(markup).to include(ERB::Util.html_escape("\"><script>alert(1)</script>"))
    end
  end
end
