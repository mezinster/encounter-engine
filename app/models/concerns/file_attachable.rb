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
  # every player sees. `locale.presence` folds "" (what a form sends for the
  # primary tab) onto it.
  def replace_attached_files(game_file_ids, locale)
    slot = locale.presence
    wanted = owning_game ? owning_game.game_files.where(:id => Array(game_file_ids)).pluck(:id) : []

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
  # own language's, in position order.
  def attached_files_for(locale)
    file_attachments.for_locale(locale).includes(:game_file).map(&:game_file)
  end

  private

  # Level has a game; a Hint reaches it through its level. Both can be nil on
  # an unsaved or malformed record, and `wanted` above degrades to [] there.
  def owning_game
    case self
    when Level then game
    when Hint  then level&.game
    end
  end
end
