# frozen_string_literal: true

# Compare-and-set progress with an optional device activity time.
#
# expected_version guards against lost updates, and a client mutation UUID
# makes an uncertain retry idempotent. observed_at is when the reader actually
# reached the place; it is never inferred from the upload time. A checkpoint
# observed before the stored one cannot replace it even when its version
# matches, so late uploads from an offline device cannot rewind a newer place.
# Equal times with different places need a choice. resolve_conflict records an
# explicit "keep this device" choice and bypasses only that chronological guard.
class Consumer::ProgressWriter
  class Invalid < StandardError; end
  class Conflict < StandardError
    attr_reader :progress

    def initialize(progress)
      @progress = progress
      super("Progress was updated by another device")
    end
  end

  FIELDS = %w[asset_id expected_version client_mutation_id position_seconds observed_at resolve_conflict].freeze
  OPTIONAL = %w[observed_at resolve_conflict].freeze
  UNUSABLE = Object.new.freeze
  TIMESTAMP = /\A(\d{4})-(\d{2})-(\d{2})T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d{1,9})?(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)\z/
  FUTURE_TOLERANCE = 5.minutes
  FIXED_LAYOUT = %w[pdf cbz].freeze
  FIXED_LOCATOR_KEYS = %w[href type title locations text].freeze
  FIXED_LOCATION_KEYS = %w[position progression totalProgression fragments].freeze
  MAX_PAGES = 100_000

  # Strong parameters drop nested or array values silently. An optional field
  # that was sent but dropped must be refused, not read as "not supplied".
  def self.attributes(params)
    values = params.permit(*FIELDS, locator: {}).to_h
    OPTIONAL.each { |key| values[key] = UNUSABLE if params.key?(key) && !values.key?(key) }
    values
  end

  def initialize(user:, book:)
    @user = user
    @book = book
  end

  def call(attributes)
    values, resolve = validate(attributes)
    # Filesystem inspection stays outside the write transaction.
    asset = Consumer::LibraryAssets.new(@book, formats: Consumer::ReaderFormats::SUPPORTED).find(values[:asset_id])
    raise Invalid, "This asset is no longer available; refresh the publication" unless asset

    validate_fixed_layout(asset, values[:locator]) if values[:locator]

    ConsumerProgress.transaction do
      progress = @user.consumer_progresses.find_by(book: @book)
      if progress
        progress.with_lock do
          same_mutation = progress.client_mutation_id == values[:client_mutation_id]
          return progress if same_mutation && same_checkpoint?(progress, values)
          raise Conflict, progress if same_mutation || progress.version != attributes.fetch("expected_version")
          raise Conflict, progress unless resolve || chronological?(progress, values)

          progress.update!(**values, version: progress.version + 1)
        end
      else
        raise Conflict, nil unless attributes.fetch("expected_version").zero?

        progress = @user.consumer_progresses.create!(book: @book, **values, version: 1)
      end
      progress
    end
  rescue ActiveRecord::RecordNotUnique
    raise Conflict, @user.consumer_progresses.find_by(book: @book)
  end

  private

  def same_checkpoint?(progress, values)
    progress.attributes.slice("asset_id", "locator", "position_seconds") == values.slice(:asset_id, :locator, :position_seconds).stringify_keys &&
      progress.observed_at == values[:observed_at]
  end

  # Unknown activity times (old rows and old clients) keep the version-only
  # flow. A known stored time is only replaced by a later observation, or an
  # equal one for the same place.
  def chronological?(progress, values)
    return true if progress.observed_at.nil? || values[:observed_at].nil?
    return true if values[:observed_at] > progress.observed_at

    values[:observed_at] == progress.observed_at &&
      progress.attributes.slice("asset_id", "locator", "position_seconds") == values.slice(:asset_id, :locator, :position_seconds).stringify_keys
  end

  def validate(attributes)
    unless attributes.is_a?(Hash) && attributes["asset_id"].is_a?(String) && attributes["asset_id"].match?(/\A[0-9a-f]{64}\z/) &&
        attributes["expected_version"].is_a?(Integer) && attributes["expected_version"].between?(0, 2**63 - 2) &&
        attributes["client_mutation_id"].is_a?(String) && attributes["client_mutation_id"].match?(/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i)
      raise Invalid, "An asset, expected version, and UUID mutation ID are required"
    end
    resolve = attributes["resolve_conflict"]
    raise Invalid, "resolve_conflict must be true or false" unless [ nil, true, false ].include?(resolve)

    values = attributes.slice("asset_id", "client_mutation_id").symbolize_keys
    values[:observed_at] = observed_at(attributes["observed_at"])
    unless @book.audiobook?
      locator = attributes["locator"]
      raise Invalid, "A bounded relative ebook locator is required" unless valid_locator?(locator) && attributes["position_seconds"].nil?

      [ values.merge(locator: locator, position_seconds: nil), resolve == true ]
    else
      seconds = attributes["position_seconds"]
      unless seconds.is_a?(Numeric) && seconds.finite? && seconds.between?(0, 31.days.to_i) && attributes["locator"].nil?
        raise Invalid, "A valid listening position is required"
      end
      [ values.merge(locator: nil, position_seconds: seconds.to_f), resolve == true ]
    end
  end

  # ISO-8601 with an explicit zone, stored as UTC milliseconds. A time more than
  # five minutes ahead of the server is refused rather than trusted or clamped.
  def observed_at(value)
    return nil if value.nil?
    # Time.iso8601 rolls 30 February into March; check the calendar date first.
    match = TIMESTAMP.match(value) if value.is_a?(String)
    raise Invalid, "observed_at must be an ISO-8601 time with a time zone" unless match && Date.valid_date?(*match.captures.map(&:to_i))

    time = Time.iso8601(value)
    raise Invalid, "observed_at is too far in the future; check this device's clock" if time > Time.current + FUTURE_TOLERANCE

    time.utc.floor(3)
  end

  # PDF and CBZ places name a page. A PDF has one resource, "document.pdf";
  # the page is checked only against the bound here, since the server never
  # parses PDF pages. A CBZ page must be item N of this exact generation's
  # reading order. A text position (such as an EPUB CFI) is never accepted.
  def validate_fixed_layout(asset, locator)
    return unless FIXED_LAYOUT.include?(asset.format)

    locations = locator["locations"]
    position = locations["position"]
    unless (locator.keys - FIXED_LOCATOR_KEYS).empty? && (locations.keys - FIXED_LOCATION_KEYS).empty? &&
        position.is_a?(Integer) && position.between?(1, MAX_PAGES) &&
        (locator["title"].nil? || (locator["title"].is_a?(String) && locator["title"].bytesize <= 1024)) &&
        (locator["text"].nil? || locator["text"].is_a?(Hash))
      raise Invalid, "A page place needs a one-based locations.position and no text position"
    end

    if asset.format == "pdf"
      fragments = locations["fragments"]
      unless locator["href"] == "document.pdf" && locator["type"] == "application/pdf" && (fragments.nil? || fragments == [ "page=#{position}" ])
        raise Invalid, "A PDF place is document.pdf with type application/pdf and an optional page=N fragment"
      end
    else
      raise Invalid, "A comic place has no fragments" if locations.key?("fragments")

      _, pages = Consumer::LibraryAssets.new(@book, formats: %w[cbz]).reading_order(asset.id)
      page = pages[position - 1]
      unless page && locator["href"] == page[:href] && locator["type"] == page[:media_type]
        raise Invalid, "This page is not page #{position} of the comic's reading order; refresh the publication"
      end
    end
  end

  def valid_locator?(locator)
    return false unless locator.is_a?(Hash) && locator.to_json.bytesize <= 16.kilobytes

    href = locator["href"]
    return false unless href.is_a?(String) && href.present? && href.bytesize <= 2048

    decoded = URI::DEFAULT_PARSER.unescape(href)
    return false if decoded.match?(%r{\A/|:|\\|[\x00-\x1f]}) || decoded.split("/").include?("..")

    locations = locator["locations"]
    return false unless locations.is_a?(Hash)

    %w[progression totalProgression].all? do |key|
      !locations.key?(key) || (locations[key].is_a?(Numeric) && locations[key].finite? && locations[key].between?(0, 1))
    end && (!locations.key?("position") || (locations["position"].is_a?(Integer) && locations["position"].positive?))
  end
end
