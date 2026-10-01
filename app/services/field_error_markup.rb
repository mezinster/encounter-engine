# app/services/field_error_markup.rb
#
# Rails' field_error_proc, set in config/application.rb. Called once per
# form control or label whose attribute has errors, with the tag Rails just
# rendered.
#
# Rails' default wraps the tag in <div class="field_with_errors">. That div
# lands between .field and its <label>, breaking `.field > label`, so every
# invalid field silently lost its label style. This marks the tag itself
# instead and, for a control with an id, puts the field's own messages
# directly after it -- on a phone the summary box at the top of the form is
# usually scrolled out of view.
#
# Radios and checkboxes get the marks but no span. Each sits inside its own
# <label class="check">, so a span after the control would land inside the
# label, become part of the control's accessible name, and be read twice (once
# as the name, once as the aria-describedby description). The label's danger
# colour (`.field label.check:has(.is-invalid)`) and the error summary box
# carry the message for them instead.
#
# The opening tag is edited as a string, never parsed and re-serialised: a
# <textarea> opens with a newline Rails adds on purpose (the HTML parser eats
# the first one), and re-serialising would silently drop a leading newline
# from the user's own text.
class FieldErrorMarkup
  OPEN_TAG = %r{\A<(input|select|textarea|label)\b([^>]*?)(\s*/)?>}m
  CHECK_TYPES = %w[radio checkbox].freeze

  def self.call(html_tag, instance)
    new(html_tag, instance).to_html
  end

  def initialize(html_tag, instance)
    @html_tag = html_tag.to_s
    @instance = instance
  end

  def to_html
    match = OPEN_TAG.match(@html_tag) or return @html_tag.html_safe
    name, attrs, slash = match[1], match[2], match[3]
    type = attribute(attrs, "type")
    return @html_tag.html_safe if type == "hidden"

    attrs = with_class(attrs)
    return rebuild(name, attrs, slash, match.post_match, "") if name == "label"

    attrs += ' aria-invalid="true"'
    id = attribute(attrs, "id")
    messages = messages_for_attribute
    span = ""
    if id && !CHECK_TYPES.include?(type) && messages.any?
      error_id = "#{id}-error"
      attrs += %( aria-describedby="#{CGI.escapeHTML(error_id)}")
      span = %(<span class="field-error" id="#{CGI.escapeHTML(error_id)}">) +
             CGI.escapeHTML(messages.join("; ")) + "</span>"
    end
    rebuild(name, attrs, slash, match.post_match, span)
  end

  private

  def rebuild(name, attrs, slash, rest, span)
    "<#{name}#{attrs}#{slash}>#{rest}#{span}".html_safe
  end

  # Rails always double-quotes attribute values and escapes them, so a value
  # cannot contain a bare double quote or ">".
  def attribute(attrs, name)
    attrs[/\s#{name}="([^"]*)"/, 1]
  end

  def with_class(attrs)
    if attrs.match?(/\sclass="/)
      attrs.sub(/\sclass="([^"]*)"/) { %( class="#{[$1, "is-invalid"].reject(&:empty?).join(" ")}") }
    else
      attrs + ' class="is-invalid"'
    end
  end

  # ActiveModelInstanceTag#error_message is Rails' public reader for
  # object.errors[@method_name]; no private ivar needed.
  def messages_for_attribute
    return [] unless @instance.respond_to?(:error_message) && @instance.object.respond_to?(:errors)

    Array(@instance.error_message).map(&:to_s)
  end
end
