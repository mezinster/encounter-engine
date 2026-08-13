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
  def attached_files_for(locale)
    file_attachments.for_locale(locale).includes(:game_file)
      .sort_by { |a| [ a.locale.nil? ? 0 : 1, a.position, a.id ] }
      .map(&:game_file)
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
