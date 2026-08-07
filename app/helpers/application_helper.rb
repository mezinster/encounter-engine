# -*- encoding : utf-8 -*-
# Renamed from global_helpers.rb (module GlobalHelpers) in Task 9c's fix
# round 1. The old name was never actually wired up for real requests:
# ActionController::Railties::Helpers only calls `helper :all` once, when
# ApplicationController itself is defined (it's the sole direct subclass of
# ActionController::Base), and that scan
# (ActionController::Helpers#all_helpers_from_path) globs
# `app/helpers/**/*_helper.rb` -- SINGULAR. "global_helpers.rb" is plural and
# never matched, so `error_messages_for` was undefined on every real request
# to a template that calls it (/signup, /games/new, /games/:id/edit, and 9
# more -- see task-9c-report.md's fix-round-1 addendum). A rspec-rails view
# spec never caught this either: it doesn't ask the controller what helpers
# it has, it independently checks `Object.const_defined?('ApplicationHelper')`
# (rspec-rails' ViewExampleGroup::ClassMethods#_default_helpers) and includes
# that by literal name. Naming the file/module the Rails-conventional way
# fixes both: the `**/*_helper.rb` glob now matches, and the literal
# `ApplicationHelper` constant now exists, so it's genuinely available in
# every real controller (inherited from ApplicationController._helpers) and
# every view spec (rspec-rails' own convention), with no explicit `helper`
# call or spec-side stub required anywhere.
module ApplicationHelper
  # Shared with GamePassing rather than reimplemented: the listing renders how
  # long a game ran, which is the same arithmetic the play screen uses for
  # time at a level.
  include TimeFormatting

  # helpers defined here available to all views.

  # Ports merb-helpers' Errorifier#error_messages_for
  # (merb-helpers/lib/merb-helpers/form/builder.rb:403-416) and
  # its default options from the top-level wrapper
  # (merb-helpers/lib/merb-helpers/form/helpers.rb:435-441). Both removed
  # by Task 13; see git history for the original source.
  # Rails' `errors.full_messages` is composed the same way the Merb original
  # relied on (humanized attribute + message), so the rendered text is
  # unchanged -- only the framework wiring is new.
  #
  # Call sites match the Merb originals verbatim, e.g.:
  #   error_messages_for @user
  #   error_messages_for @user, header: "<h2>Ошибка</h2>"
  #
  # Before (Merb, merb-helpers/.../builder.rb:404-416, removed by Task 13):
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

  # Each link opens the right form on the right language tab, so the author
  # goes from "what is missing" to "fixing it" in one click.
  #
  # The Question branch is currently unreachable: Question::TRANSLATABLE_FIELDS
  # is deliberately empty (the `questions` column is vestigial), so
  # Game#missing_translations never yields a Question entry. Kept anyway --
  # it costs nothing, keeps the case statement symmetric with the other three
  # translatable record types, and stops this helper from silently returning
  # nil the day a Question field becomes translatable.
  def missing_translation_path_for(entry)
    case entry.record
    when Game     then edit_game_path(entry.record, :tab => entry.locale)
    when Level    then edit_game_level_path(entry.record.game, entry.record, :tab => entry.locale)
    when Hint     then edit_game_level_hint_path(entry.record.level.game, entry.record.level,
                                                 entry.record, :tab => entry.locale)
    when Question then new_game_level_question_path(entry.record.level.game, entry.record.level,
                                                    :tab => entry.locale)
    end
  end

  # "2099-01-01 13:00 (+01:00)". Only for the timestamps a user acts on --
  # game start, registration deadline, and the results screen's heading. A zone
  # marker on every line of an answer log is noise that makes the few that
  # matter harder to notice, not easier.
  #
  # The numeric offset rather than the zone's abbreviation, deliberately:
  # abbreviations are ambiguous across regions -- IST is three different zones
  # -- while an offset is unambiguous to anyone comparing two times, which is
  # the only thing this label is for.
  def l_with_zone(time, format:)
    return nil if time.nil?

    zoned_time = time.in_time_zone(Time.zone)
    "#{l(zoned_time, :format => format)} (#{zoned_time.formatted_offset})"
  end

  # The messengers a user has ticked, as one comma-joined string, or nil when
  # none are. Three views render this; a row per messenger would triple the
  # height of a two-column table to show five booleans.
  #
  # Ordered by the flag order on the form, not alphabetically, so the reading
  # order matches the order the user ticked them in.
  MESSENGER_FLAGS = %w[telegram whatsapp viber signal max].freeze

  def messenger_list_for(user)
    ticked = MESSENGER_FLAGS.select { |name| user.public_send("on_#{name}") }
    return nil if ticked.empty?

    ticked.map { |name| t("messengers.#{name}") }.join(", ")
  end
end
