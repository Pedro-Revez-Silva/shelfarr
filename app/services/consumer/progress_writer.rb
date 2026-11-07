# frozen_string_literal: true

class Consumer::ProgressWriter
  class Invalid < StandardError; end
  class Conflict < StandardError
    attr_reader :progress

    def initialize(progress)
      @progress = progress
      super("Progress was updated by another device")
    end
  end

  def initialize(user:, book:)
    @user = user
    @book = book
  end

  def call(attributes)
    values = validate(attributes)
    # Filesystem inspection stays outside the write transaction.
    unless Consumer::LibraryAssets.new(@book).list.any? { |asset| asset.id == values[:asset_id] }
      raise Invalid, "This asset is no longer available; refresh the publication"
    end

    ConsumerProgress.transaction do
      progress = @user.consumer_progresses.find_by(book: @book)
      if progress
        progress.with_lock do
          same_mutation = progress.client_mutation_id == values[:client_mutation_id]
          if same_mutation && progress.attributes.slice("asset_id", "locator", "position_seconds") == values.slice(:asset_id, :locator, :position_seconds).stringify_keys
            return progress
          end
          raise Conflict, progress if same_mutation || progress.version != attributes.fetch("expected_version")

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

  def validate(attributes)
    unless attributes.is_a?(Hash) && attributes["asset_id"].is_a?(String) && attributes["asset_id"].match?(/\A[0-9a-f]{64}\z/) &&
        attributes["expected_version"].is_a?(Integer) && attributes["expected_version"].between?(0, 2**63 - 2) &&
        attributes["client_mutation_id"].is_a?(String) && attributes["client_mutation_id"].match?(/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i)
      raise Invalid, "An asset, expected version, and UUID mutation ID are required"
    end

    values = attributes.slice("asset_id", "client_mutation_id").symbolize_keys
    if @book.ebook?
      locator = attributes["locator"]
      raise Invalid, "A bounded relative ebook locator is required" unless valid_locator?(locator) && attributes["position_seconds"].nil?

      values.merge(locator: locator, position_seconds: nil)
    else
      seconds = attributes["position_seconds"]
      unless seconds.is_a?(Numeric) && seconds.finite? && seconds.between?(0, 31.days.to_i) && attributes["locator"].nil?
        raise Invalid, "A valid listening position is required"
      end
      values.merge(locator: nil, position_seconds: seconds.to_f)
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
