# frozen_string_literal: true

# Which reading formats a consumer client can open, from the additive v1
# capability header `X-Shelfarr-Reader-Formats: epub,pdf,cbz`.
#
# Installed readers never send it, so a missing header keeps the EPUB-only
# contract they were built against: no PDF or CBZ assets, no comic records and
# their original cursor identities. Audio is unaffected. The release number is
# not a format capability.
module Consumer::ReaderFormats
  class Invalid < StandardError; end

  HEADER = "X-Shelfarr-Reader-Formats"
  SUPPORTED = %w[cbz epub pdf].freeze
  DEFAULT = %w[epub].freeze
  GRAPHIC = %w[cbz pdf].freeze
  MAX_BYTES = 64

  Selection = Data.define(:formats, :declared) do
    def include?(format) = formats.include?(format)
    # Comic records are listed only for clients that open a fixed-layout format.
    def graphic? = formats.intersect?(GRAPHIC)
    def default? = formats == DEFAULT
  end

  LEGACY = Selection.new(formats: DEFAULT, declared: false)
  # The browser reader opens every supported format.
  WEB = Selection.new(formats: SUPPORTED, declared: true)

  module_function

  def from(request)
    parse(request.headers[HEADER])
  end

  # A bounded lowercase comma list of known names. Duplicates and order are
  # normalized, so equal selections share cursors; empty or unknown names are
  # refused rather than guessed.
  def parse(value)
    return LEGACY if value.nil?
    raise Invalid, "Declare reader formats as a comma-separated list such as epub,pdf,cbz" unless value.is_a?(String) && value.bytesize.between?(1, MAX_BYTES)

    names = value.split(",", -1).map { |name| name.strip }
    unless names.all? { |name| SUPPORTED.include?(name) }
      raise Invalid, "Unknown or empty reader format; supported formats are #{SUPPORTED.join(",")}"
    end

    Selection.new(formats: names.uniq.sort.freeze, declared: true)
  end
end
