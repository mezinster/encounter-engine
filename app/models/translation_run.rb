# app/models/translation_run.rb
#
# One press of "Translate". Holds the work counters the run page renders and
# the token totals the run actually spent.
class TranslationRun < ApplicationRecord
  belongs_to :game
  belongs_to :actor, :class_name => "User"
  has_many :translation_proposals, :dependent => :destroy

  PENDING   = "pending".freeze
  RUNNING   = "running".freeze
  SUCCEEDED = "succeeded".freeze
  FAILED    = "failed".freeze
  CANCELLED = "cancelled".freeze

  TERMINAL_STATES = [ SUCCEEDED, FAILED, CANCELLED ].freeze
  ACTIVE_STATES   = [ PENDING, RUNNING ].freeze

  validates :model, :presence => true
  validates :state, :inclusion => { :in => ACTIVE_STATES + TERMINAL_STATES }

  scope :active_for, ->(game) { where(:game_id => game.id, :state => ACTIVE_STATES) }
  scope :newest_first, -> { order(:created_at => :desc) }

  STALE_AFTER = 15.minutes

  # A thread killed mid-run -- by a deploy, an OOM, a restart -- leaves its row
  # in `running` forever, and the one-active-run-per-game rule then locks the
  # game out of translation permanently. Called opportunistically from the
  # controller rather than from a scheduler, because this application has no
  # scheduler and adding one for this would cost more than it saves.
  def self.sweep_stale!(older_than: STALE_AFTER)
    where(:state => ACTIVE_STATES)
      .where("updated_at < ?", older_than.ago)
      .update_all(:state => FAILED,
                  :error_message => "abandoned: no progress for #{older_than.inspect}",
                  :finished_at => Time.now,
                  :updated_at => Time.now)
  end

  # Same shape as Game#available_locale_list, deliberately -- an operator
  # reading either column in a console should not have to learn two formats.
  def target_locale_list
    self.target_locales.to_s.split(",").map(&:strip).reject(&:blank?)
  end

  def target_locale_list=(list)
    self.target_locales = Array(list).map(&:to_s).map(&:strip).reject(&:blank?).join(",")
  end

  def running?
    self.state == RUNNING
  end

  def terminal?
    TERMINAL_STATES.include?(self.state)
  end

  # Guarded, because a run whose work-list came out empty has fields_total 0
  # and the run page divides by this to draw the progress bar.
  def progress_fraction
    return 0.0 if self.fields_total.to_i.zero?

    self.fields_done.to_f / self.fields_total
  end
end
