# app/services/sentence_join.rb
#
# Joins validation messages that are whole sentences into one flash.
#
# The Merb-era messages are sentences ("Вы не ввели название"), and since
# 2026-10-01 they render without a field name (see the `format: "%{message}"`
# keys and spec/i18n_sentence_messages_spec.rb). `to_sentence` joined them with
# "и" -- "… :-) и Вы указали …" -- and a bare space ran them together, because
# most carry no terminal punctuation. So: give each one a full stop unless it
# already ends in one (".", "!", "?", "…", or the ":-)" a few of them close
# with), then join with a space.
module SentenceJoin
  TERMINAL = /[.!?…)]\z/

  def self.call(messages)
    messages.map { |message|
      text = message.to_s.rstrip
      text.match?(TERMINAL) ? text : "#{text}."
    }.join(" ")
  end
end
