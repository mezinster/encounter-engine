# -*- encoding : utf-8 -*-
#
# Shared by Level and Hint: both own an ordered list of GameFiles, per locale.
module FileAttachable
  extend ActiveSupport::Concern

  included do
    has_many :file_attachments, -> { order(:position) },
             :as => :attachable, :dependent => :destroy
    has_many :game_files, :through => :file_attachments
  end

  # Replace ONE locale's slot, leaving every other slot alone.
  #
  # nil is a real value here, not "unset": it is the language-neutral strip
  # every player sees. The picker posts locale="" for the primary tab, and a
  # hand-edited form could post whitespace padding or a locale this app does
  # not serve. `.strip.presence` folds "" and "  " onto nil (so padding
  # doesn't create a THIRD slot that `for_locale` can never match), and an
  # unserved locale is refused the same way a foreign file id is refused
  # below: no slot is touched and nothing raises.
  def replace_attached_files(game_file_ids, locale)
    slot = locale.to_s.strip.presence
    return if slot && !I18n.available_locales.map(&:to_s).include?(slot)

    game = owning_game
    return if game.nil?

    wanted = game.game_files.where(:id => Array(game_file_ids)).pluck(:id)

    transaction do
      current = file_attachments.where(:locale => slot)
      current.where.not(:game_file_id => wanted).destroy_all

      already = file_attachments.where(:locale => slot).pluck(:game_file_id)
      (wanted - already).each do |id|
        file_attachments.create!(:game_file_id => id, :locale => slot)
      end
    end

    file_attachments.reset
  end

  # What a player reading `locale` should see: the neutral strip plus their
  # own language's, in position order -- neutral first in full, then the
  # language slot in full. `position` is scoped PER SLOT (see FileAttachment's
  # acts_as_list scope), so both slots independently start at 1: a plain
  # ORDER BY position interleaves the two slots and lets ties fall to
  # whatever the engine returns -- SQLite and Postgres do not agree, and
  # production runs Postgres while the suite runs SQLite. Sorting in Ruby,
  # keyed on (slot, position, id), gives one order on both engines without
  # fighting NULLS FIRST portability, and these lists are tiny (a level has a
  # handful of files) so sorting after loading costs nothing worth avoiding.
  # Task 3B addition: when the caller has already preloaded file_attachments
  # (Level.includes(:file_attachments => ...) / :hints => {:file_attachments
  # => ...}), reading through .for_locale(locale).includes(:game_file) below
  # would still hit the database -- calling ANY scope method (.for_locale,
  # .includes) on a has_many association proxy builds a fresh relation and
  # ignores the association's own loaded target, regardless of what was
  # preloaded upstream. Confirmed empirically: even with
  # `association(:file_attachments).loaded? == true`, `.includes(:x)` still
  # issued 2 queries. On the play screen (game_passings_controller.rb) that
  # turns into one query per HINT rendered -- exactly the N+1
  # spec/requests/translated_level_spec.rb's flat-query-count guard exists to
  # catch, and it did (a 10-hint page cost 9 more queries than a 1-hint page
  # before this branch was added).
  #
  # So: filter and sort in Ruby against the ALREADY-LOADED array when one
  # exists, which costs nothing extra as long as the caller also preloaded
  # :game_file (as game_passings_controller.rb now does) -- and fall back to
  # the original query-based path, unchanged, when nothing was preloaded.
  # Every existing caller (the picker, this file's own spec) never preloads
  # file_attachments before calling this, so they all keep taking the
  # original path with identical output.
  def attached_files_for(locale)
    rows = if file_attachments.loaded?
             file_attachments.select { |a| a.locale.nil? || a.locale == locale.to_s }
           else
             file_attachments.for_locale(locale).includes(:game_file).to_a
           end

    rows.sort_by { |a| [ a.locale.nil? ? 0 : 1, a.position, a.id ] }
        .map(&:game_file)
  end

  # The ids attached in exactly ONE slot -- unlike attached_files_for, which
  # unions the neutral strip with a language for what a PLAYER sees, the
  # picker's pre-checked state must reflect only the slot the active tab is
  # about to replace, nothing more. Same `.strip.presence` folding as
  # replace_attached_files, so a picker rendered for locale "" (the primary
  # tab) reads the same slot that locale nil/"" writes to.
  #
  # Works on an unsaved record too -- a new Hint's form renders this picker
  # via the shared _form partial -- because a has_many association on a
  # not-yet-persisted owner starts as an empty in-memory collection rather
  # than issuing a query.
  #
  # COUPLING WITH attached_files_for, worth knowing before combining the two
  # in one request: `.select { ... }` here is Enumerable#select (a block was
  # given), which loads the WHOLE file_attachments association into memory
  # as a side effect -- `file_attachments.loaded?` is true afterwards. If
  # something later in the same request then calls attached_files_for, it
  # takes that method's PRELOADED branch (reads the now-loaded array in
  # Ruby) rather than its query-based fallback, exactly as if the caller had
  # preloaded on purpose. That is not a correctness problem -- the preloaded
  # branch's filter-and-sort gives the same result either way -- but it is a
  # performance one if :game_file was not ALSO preloaded: `.map(&:game_file)`
  # on an unpreloaded loaded association is one query per attachment, worse
  # than the fallback branch's flat two. No page does both today (this picker
  # never renders the player-facing strip in the same request), so nothing
  # observes it -- but a future caller that does both without preloading
  # :game_file would get a silent N+1 rather than a wrong answer.
  def attached_file_ids_in_slot(locale)
    slot = locale.to_s.strip.presence
    file_attachments.select { |a| a.locale == slot }.map(&:game_file_id)
  end

  private

  # Level has a game; a Hint reaches it through its level. Both can be nil on
  # an unsaved or malformed record. `replace_attached_files` returns early
  # when this is nil, rather than proceeding with an empty `wanted` -- a
  # destroy_all still runs against whatever's in the slot, and "cannot verify
  # ownership" must refuse, not silently wipe what's already attached.
  def owning_game
    case self
    when Level then game
    when Hint  then level&.game
    end
  end
end
