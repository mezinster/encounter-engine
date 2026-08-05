# -*- encoding : utf-8 -*-
class Hint < ApplicationRecord
  include TranslatableContent

  TRANSLATABLE_FIELDS = %w[text].freeze

  def translation_game
    self.level&.game
  end

  belongs_to :level, optional: true

  def delay_in_minutes
    self.delay.nil? ? nil : self.delay / 60
  end

  def delay_in_minutes=(value)
    self.delay = value.to_i * 60
  end

  def ready_to_show?(current_level_entered_at, now = Time.now)
    seconds_passed = now - current_level_entered_at
    seconds_passed >= self.delay
  end

  def available_in(current_level_entered_at, now = Time.now)
    (current_level_entered_at - now).to_i + self.delay
  end
end
