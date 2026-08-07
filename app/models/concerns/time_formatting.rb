# Elapsed-interval formatting, shared by the model that measures time at a
# level and the views that render how long a game ran. Extracted from
# GamePassing#seconds_fraction_to_time, which was private and carried a
# standing "TODO: keep SRP, extract this to a separate helper".
#
# Deliberately free of t(): it returns numbers and a fixed digit format, so
# there is no locale for it to be wrong about. Words like "hours" belong to
# the locale keys at the call site.
module TimeFormatting
  # "HH:MM:SS", not wrapped at 24 hours -- a team can legitimately sit on one
  # level longer than a day, and 25:00:00 says that where 01:00:00 would lie.
  def seconds_to_hms(seconds)
    total   = seconds.to_i
    hours   = total / 3600
    minutes = (total % 3600) / 60
    secs    = total % 60

    "%02d:%02d:%02d" % [hours, minutes, secs]
  end

  # Whole hours and the remaining whole minutes, for prose durations.
  def hours_and_minutes(seconds)
    total = seconds.to_i
    [total / 3600, (total % 3600) / 60]
  end
end
