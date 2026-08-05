# app/models/content_translation.rb
#
# One translated field for one record. Holds NON-primary languages only: the
# primary language lives in the model's own column, which is what lets existing
# games keep working byte-identically.
class ContentTranslation < ApplicationRecord
  belongs_to :translatable, polymorphic: true

  validates :field,  presence: true
  validates :locale, presence: true
end
