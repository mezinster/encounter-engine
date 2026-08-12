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

    # build_li/header are option-provided *format strings* and are
    # deliberately NOT escaped -- they're developer-supplied and legitimately
    # contain HTML (every real call site passes a header like "<h2>...</h2>").
    # What must be escaped is the *values* substituted into them: error_class
    # is a value a caller controls (options[:error_class]); errors.size is an
    # integer (ERB::Util.html_escape here is ceremony -- harmless, kept to
    # stay deliberate rather than lucky, not because an Integer can carry
    # markup). Each full_message can embed arbitrary submitter-controlled
    # text -- see Game#available_locales_are_known, whose %{locales} is built
    # from params[:game][:available_locale_list] via unknown.join(", ") --
    # so its escaping has to be unconditional: CGI.escapeHTML, not
    # ERB::Util.html_escape, which is a no-op on a string that already
    # answers true to html_safe?. A full_message can be html_safe already,
    # e.g. via an `_html`-suffixed i18n key (Rails marks those safe
    # automatically); CGI.escapeHTML escapes it regardless.
    header_message = header % [ERB::Util.html_escape(errors.size), errors.size == 1 ? "" : "s"]

    markup = +"<div class='#{ERB::Util.html_escape(error_class)}'>#{header_message}<ul>"
    errors.full_messages.each { |message| markup << (build_li % CGI.escapeHTML(message.to_s)) }
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
    # Options have no edit screen of their own -- they live on their question's
    # index page, which is where the translation tabs are. Without this branch
    # the helper returned nil for an Option entry, so the missing-translations
    # panel listed the field and offered a link that went nowhere: the one
    # record type whose translation actually blocked publication was also the
    # one you could not click through to.
    when Option   then game_level_question_options_path(entry.record.question.level.game,
                                                        entry.record.question.level,
                                                        entry.record.question,
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

  # The countdown pluralises client-side: _countdown.html.erb emits a
  # three-element array per unit (shared.countdown.years, .days, ...) and this
  # function, which maps a number to one of those three indices. The browser
  # calls it once a second, so the rule has to be JavaScript -- it cannot be
  # done in Ruby at render time, because n changes after the page is sent.
  #
  # It used to be one hard-coded East Slavic rule for every locale. That is
  # correct for ru/uk/be and wrong elsewhere, in a way nobody noticed because
  # it is only visibly wrong at particular numbers: its "one" slot fires for
  # 1, 21, 31, 101..., which is right for Russian ("21 год") and wrong for
  # Polish, where only a bare 1 takes the singular ("21 lat", not "21 rok").
  # English had the same defect since the file was written ("21 year").
  #
  # Three families cover all seven locales. Anything unlisted gets the
  # one/other rule, which is the safe default: it is correct for a language
  # with simple pluralisation, and for a language whose three array slots hold
  # the same word (tr, ka) every index is correct anyway.
  #
  # spec/helpers/countdown_plural_spec.rb runs these through node, rather than
  # reimplementing them in Ruby -- a Ruby mirror would agree with itself while
  # the shipped JavaScript stayed broken.
  COUNTDOWN_PLURAL_FUNCTIONS = {
    # one: n%10==1 and n%100!=11; few: n%10 in 2..4 and n%100 not in 12..14;
    # many: everything else. The (n%100 < 10 || n%100 >= 20) clause is how the
    # original spelled "not in 12..14", given n%10 is already known to be 2-4.
    :east_slavic => "function(n) { return n % 10 == 1 && n % 100 != 11 ? 0 : " \
                    "(n % 10 >= 2 && n % 10 <= 4 && (n % 100 < 10 || n % 100 >= 20) ? 1 : 2); }",
    # Identical to the above except for the "one" slot, which in Polish is a
    # bare 1 and nothing else. That single difference is the whole bug.
    :polish      => "function(n) { return n == 1 ? 0 : " \
                    "(n % 10 >= 2 && n % 10 <= 4 && (n % 100 < 10 || n % 100 >= 20) ? 1 : 2); }",
    :one_other   => "function(n) { return n == 1 ? 0 : 1; }"
  }.freeze

  COUNTDOWN_PLURAL_RULES = {
    :ru => :east_slavic, :uk => :east_slavic, :be => :east_slavic,
    :pl => :polish
  }.freeze

  # html_safe because this is a fixed, developer-authored JavaScript constant
  # chosen by locale -- no user input reaches it, and the whole point is that
  # it is emitted as code rather than escaped text.
  def countdown_plural_function(locale = I18n.locale)
    rule = COUNTDOWN_PLURAL_RULES.fetch(locale.to_sym, :one_other)
    COUNTDOWN_PLURAL_FUNCTIONS.fetch(rule).html_safe
  end

  # "Уровень 3" or "Ур. 3 → подсказка 2". Returns nil for an attachment whose
  # owner has been destroyed, so a stale row renders as nothing rather than
  # raising on a live page.
  def attachment_place(attachment)
    case attachment.attachable
    when Level then attachment.attachable.name
    when Hint  then "#{attachment.attachable.level&.name} → #{t("game_files.table.hint")}"
    end
  end

  # The quota bar's fill, as a whole-number percentage, clamped to 100.
  #
  # A zero quota is NOT hypothetical: Setting's own comment calls zero the
  # documented "off" switch an operator reaches for during an incident, the
  # validation is greater_than_or_equal_to: 0, and the key sits on the admin
  # settings page. Written inline in the view as
  # `[ (used * 100.0 / quota).round, 100 ].min`, zero produced NaN.round with
  # no files and Infinity.round with any -- BOTH raise FloatDomainError, and
  # they took down the very page every author is redirected to after every
  # upload and every delete. The upload path already degrades correctly at
  # zero (it refuses with «осталось 0 МБ из 0 МБ»); only the page was broken.
  #
  # 100, not 0, is the honest answer at a zero quota: there is no room, so the
  # bar is full. Reading it as empty would invite an author to keep trying.
  def quota_bar_percentage(used_megabytes, quota_megabytes)
    return 100 if quota_megabytes.to_i.zero?

    [ (used_megabytes * 100.0 / quota_megabytes).round, 100 ].min
  end
end
