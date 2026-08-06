# Rails' autosave validation reports an invalid child record as
# "<Association> имеет неверное значение" -- the humanised name of an
# association the author has never heard of, with no hint of what is actually
# wrong.
#
# Concretely, before this existed: submitting the new-level form with an empty
# code showed "Questions имеет неверное значение". The useful message was two
# levels down and had been correctly translated since the Merb port --
# ru.yml's answer.value.blank, "Вы не ввели вариант кода" -- but nothing ever
# carried it up. The chain was:
#
#   Answer   "Вы не ввели вариант кода"          <- the real message
#     ^ autosave
#   Question "Answers имеет неверное значение"   <- what the add-code form showed
#     ^ autosave
#   Level    "Questions имеет неверное значение" <- what the new-level form showed
#
# Promoting is done per level of nesting: Level promotes from :questions, and
# Question promotes from :answers, so a Level's promotion sees a Question that
# has already promoted from its own answers and the real message reaches the
# top in one pass.
module ChildErrorPromotion
  extend ActiveSupport::Concern

  class_methods do
    # Call AFTER the has_many it names. Rails registers the autosave validation
    # when the association is declared, and validations run in declaration
    # order -- declaring this first would inspect errors that have not been
    # populated yet.
    def promotes_errors_from(association)
      validate do
        next if errors[association].blank?

        errors.delete(association)

        # `message`, not `full_message`: these are complete sentences, and
        # full_message prefixes the humanised attribute name, giving
        # "Value Вы не ввели вариант кода".
        #
        # Added to :base for the same reason -- :base is the only key whose
        # format carries no attribute prefix.
        #
        # uniq because a level with three empty codes has one problem to
        # report, not the same sentence three times.
        messages = public_send(association)
                     .reject { |child| child.valid? }
                     .flat_map { |child| child.errors.map(&:message) }

        messages.uniq.each { |message| errors.add(:base, message) }
      end
    end
  end
end
