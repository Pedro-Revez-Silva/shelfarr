# frozen_string_literal: true

# SMIL 3.0 clock values, as EPUB Media Overlays use them for clipBegin and
# clipEnd (https://www.w3.org/TR/SMIL3/smil-timing.html#q22), converted to
# whole milliseconds:
#
#   Full clock     "1:02:03.5"  hours:minutes:seconds(.fraction)
#   Partial clock  "02:03.5"    minutes:seconds(.fraction)
#   Timecount      "3.5", "3.5s", "250ms", "2min", "1.5h"
#
# Minutes and seconds in clock forms are two digits below 60. Anything else,
# negative values and values beyond the read-along bound are refused.
module Consumer::ReadAlong::Clock
  class Invalid < StandardError; end

  MAX_MS = 48 * 3_600_000
  FULL = /\A(\d+):([0-5]\d):([0-5]\d)(?:\.(\d+))?\z/
  PARTIAL = /\A([0-5]\d):([0-5]\d)(?:\.(\d+))?\z/
  TIMECOUNT = /\A(\d+)(?:\.(\d+))?(h|min|s|ms)?\z/
  METRIC = { "h" => 3_600_000, "min" => 60_000, "s" => 1000, "ms" => 1 }.freeze

  module_function

  def milliseconds(value)
    text = value.to_s.strip
    raise Invalid, "A clock value is empty or too long" if text.empty? || text.bytesize > 32

    ms = if (match = FULL.match(text))
      hours, minutes, seconds, fraction = match.captures
      (hours.to_i * 3600 + minutes.to_i * 60 + seconds.to_i) * 1000 + fraction_ms(fraction, 1000)
    elsif (match = PARTIAL.match(text))
      minutes, seconds, fraction = match.captures
      (minutes.to_i * 60 + seconds.to_i) * 1000 + fraction_ms(fraction, 1000)
    elsif (match = TIMECOUNT.match(text))
      whole, fraction, metric = match.captures
      unit = METRIC.fetch(metric || "s")
      whole.to_i * unit + fraction_ms(fraction, unit)
    else
      raise Invalid, "#{text.inspect} isn't a SMIL clock value"
    end
    raise Invalid, "#{text.inspect} is beyond the 48-hour read-along limit" if ms > MAX_MS

    ms
  end

  # The fraction of a unit, rounded to the nearest millisecond.
  def fraction_ms(digits, unit)
    return 0 if digits.nil?

    digits = digits[0, 9]
    (digits.to_i * unit / (10**digits.length).to_r).round
  end
end
