# A page of a relation, hand-rolled rather than a gem: this is needed on two
# screens, and the codebase deliberately hand-rolls small things and records
# why (the countdown plural rules, AnsweredQuestionsCoder). The full log also
# pages LEVELS rather than the rows it lists, which sits awkwardly on a gem's
# idiom.
module Pagination
  extend ActiveSupport::Concern

  private

  # Returns [records, current_page, total_pages].
  #
  # The requested page is clamped into 1..total_pages, so an out-of-range or
  # malformed ?page= lands on a real page rather than an empty table or a 500 --
  # the same forgiving rule ?run= follows. to_i makes "не-число" zero, which
  # clamps up to 1.
  def page_of(scope, requested, per:)
    total = (scope.count.to_f / per).ceil
    total = 1 if total < 1

    current = requested.to_i
    current = 1 if current < 1
    current = total if current > total

    [ scope.offset((current - 1) * per).limit(per), current, total ]
  end
end
