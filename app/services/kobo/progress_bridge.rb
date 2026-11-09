# frozen_string_literal: true

module Kobo
  # Shares a supported Kobo reading place with the reader owner's Shelfarr
  # progress (web, Android and iOS) for the same edition.
  #
  # Only a place Kobo names by chapter resource is shared. The resource must be
  # in the spine of the exact file generation this reader downloaded, and that
  # file must still be the publication's current consumer asset. The locator is
  # resource + progression, which the consumer contract already describes as an
  # approximate cross-engine place; Kobo span and CFI values are never copied
  # or invented. The activity time is the bookmark's own LastModified, never the
  # sync or upload time. Anything that cannot be compared automatically is kept
  # on the delivery with its reason so the owner can choose it explicitly.
  class ProgressBridge
    CHOICE_STATUSES = %w[superseded needs_choice unknown_time clock_ahead].freeze
    STATUSES = (%w[shared echo no_place unsupported edition_changed unavailable] + CHOICE_STATUSES).freeze
    MAX_SOURCE_BYTES = 2048
    MUTATION_HISTORY = 8
    EARLIEST = Time.utc(2000, 1, 1)
    class NothingToChoose < StandardError; end

    class << self
      # The same strict ISO-8601 rule as Consumer::ProgressWriter, at
      # millisecond precision. An absent, zone-less or implausible time is
      # unknown, not now.
      def activity_time(value)
        match = Consumer::ProgressWriter::TIMESTAMP.match(value) if value.is_a?(String)
        return unless match && Date.valid_date?(*match.captures.map(&:to_i))

        time = Time.iso8601(value).utc.floor(3)
        time.iso8601(3) if time >= EARLIEST
      end

      # Whether this delivery's Kobo place is the saved progress. A shared
      # place has a deterministic mutation; a chosen one is remembered.
      def written_by?(delivery, progress)
        return false unless progress&.locator.is_a?(Hash)

        observed = progress.observed_at&.utc&.iso8601(3)
        progress.client_mutation_id == mutation_for(delivery, progress.asset_id, observed, progress.locator) ||
          Array(delivery.progress_bridge&.fetch("mutations", nil)).include?(progress.client_mutation_id)
      end

      # The same Kobo place always produces the same mutation, so a repeated
      # state upload is an idempotent retry rather than new activity.
      def mutation_for(delivery, asset_id, observed_at, locator)
        digest = Digest::SHA256.hexdigest([ "kobo-progress-v1", delivery.entitlement_id, delivery.revision_id,
          asset_id, observed_at, locator.to_json ].join("\0"))
        hex = digest[0, 32]
        hex[12] = "8"
        hex[16] = ((hex[16].to_i(16) & 0x3) | 0x8).to_s(16)
        [ hex[0, 8], hex[8, 4], hex[12, 4], hex[16, 4], hex[20, 12] ].join("-")
      end
    end

    def initialize(delivery)
      @delivery = delivery
      @device = delivery.kobo_device
      @user = @device.user
      @book = delivery.book
    end

    def call(bookmark)
      return unless @device.share_progress?
      # The Kobo reporting a place Shelfarr sent it is not new reading: it
      # never becomes a new version, a new time, or a place to send back.
      return save(place(bookmark).except("source", "chapter_percent").merge("status" => "echo")) if OutboundProgress.echo?(@delivery, bookmark)

      save(evaluate(bookmark))
    rescue StandardError => error
      # The Kobo request must still succeed. Never log the place or the path.
      Rails.logger.warn("[Kobo] Reading place not shared (#{error.class.name})")
      save("status" => "unavailable")
    end

    # The owner chose the Kobo place in Shelfarr. That choice is new activity,
    # so it carries the time of the choice and resolves the conflict explicitly.
    def choose!
      bridge = @delivery.progress_bridge || {}
      raise NothingToChoose unless CHOICE_STATUSES.include?(bridge["status"]) && bridge["locator"]

      current = @user.consumer_progresses.find_by(book: @book)
      mutation = SecureRandom.uuid
      Consumer::ProgressWriter.new(user: @user, book: @book).call(
        "asset_id" => bridge["asset_id"], "locator" => bridge["locator"], "expected_version" => current&.version || 0,
        "client_mutation_id" => mutation, "observed_at" => Time.current.utc.iso8601(3), "resolve_conflict" => true)
      save(bridge.merge("status" => "shared", "reason" => "chosen", "mutation_id" => mutation))
    end

    private

    def evaluate(bookmark)
      return { "status" => "no_place" } unless bookmark.is_a?(Hash)
      # A household copy from a Kobo account is not a library edition: there is
      # no consumer asset it could honestly map to, so its place stays on the
      # reader. It must never be applied to an unrelated Book.
      return place(bookmark).except("source", "chapter_percent").merge("status" => "unsupported", "reason" => "private_edition") if @delivery.private_source?

      place = place(bookmark)
      return place unless place["status"].nil?
      return place.merge("status" => "edition_changed") unless @book&.ebook? && @book.acquired?

      edition = edition()
      return place.merge(edition) unless edition["asset_id"]

      href = resolve(place.delete("source"), edition)
      return place.except("source").merge("status" => "unsupported", "reason" => "location_not_in_edition") unless href

      locations = { "progression" => place["chapter_percent"]&./(100.0), "totalProgression" => place["percent"]&./(100.0) }.compact
      candidate = place.merge("asset_id" => edition["asset_id"], "locator" => { "href" => href["href"], "type" => href["type"], "locations" => locations })
      # The stock state endpoint does not identify a revision. Once an
      # entitlement has represented different files, even a successful GET of
      # the replacement cannot establish which copy a delayed bookmark names.
      # Preserve the candidate for an explicit choice; never auto-map it.
      return candidate.merge("status" => "needs_choice", "reason" => "edition_unverified") if @delivery.progress_generation_ambiguous?

      time = candidate["observed_at"] && Time.iso8601(candidate["observed_at"])
      return candidate.merge("status" => "unknown_time") unless time
      return candidate.merge("status" => "clock_ahead") if time > Time.current + Consumer::ProgressWriter::FUTURE_TOLERANCE

      write(candidate, time)
    end

    def place(bookmark)
      percent = percentage(bookmark["ProgressPercent"])
      chapter = percentage(bookmark["ContentSourceProgressPercent"])
      location = bookmark["Location"]
      source = location["Source"] if location.is_a?(Hash)
      type = location["Type"] if location.is_a?(Hash)
      summary = { "percent" => percent == :invalid ? nil : percent, "observed_at" => activity_time(bookmark["LastModified"]),
        "location_type" => type.is_a?(String) && type.match?(/\A[A-Za-z]{1,32}\z/) ? type : nil }.compact
      return summary.merge("status" => "unsupported", "reason" => "invalid_percent") if [ percent, chapter ].include?(:invalid)

      unless source.is_a?(String) && source.present?
        return summary.merge("status" => percent.to_f.positive? ? "unsupported" : "no_place", "reason" => percent.to_f.positive? ? "no_location" : nil).compact
      end
      return summary.merge("status" => "unsupported", "reason" => "location_not_in_edition") if source.bytesize > MAX_SOURCE_BYTES

      summary.merge("source" => source, "chapter_percent" => chapter).compact
    end

    def percentage(value)
      return nil if value.nil?
      return :invalid unless value.is_a?(Numeric) && value.finite? && value.between?(0, 100)

      value.to_f
    end

    def activity_time(value)
      self.class.activity_time(value)
    end

    # Proof that the place belongs to the publication's current consumer asset:
    # list the assets first, then open the delivered file pinned to the exact
    # generation the reader downloaded. A later change to the file changes its
    # change time, so either the fingerprint check or the asset check fails.
    def edition
      return { "status" => "edition_changed", "reason" => "not_downloaded" } if @delivery.last_download_at.nil?

      assets = Consumer::LibraryAssets.new(@book).list
      file = @delivery.open_file
      stat = file.stat
      matches = assets.select { |asset| asset.device == stat.dev && asset.inode == stat.ino && asset.size_bytes == stat.size }
      return { "status" => "edition_changed", "reason" => "not_a_current_asset" } unless matches.one?

      KoboPublication.new(@book).reading_order(file).merge("asset_id" => matches.first.id)
    rescue KoboPublication::Unavailable, Consumer::LibraryAssets::Unavailable
      { "status" => "edition_changed", "reason" => "file_changed" }
    ensure
      file&.close unless file&.closed?
    end

    # Kobo names resources as a ZIP path, or prefixed with the book's content
    # ID ("<id>!!OEBPS/Text/ch.xhtml" or "<id>!OEBPS!Text/ch.xhtml"). A place is
    # supported only when exactly one spine resource matches.
    def resolve(source, edition)
      path = URI::DEFAULT_PARSER.unescape(source.sub(/[?#].*\z/, ""))
      return unless path.valid_encoding? && !path.match?(/[\x00-\x1f\\]/)

      parts = path.split("!")
      path = parts.drop(1).reject(&:empty?).join("/") if parts.size > 1
      path = path.delete_prefix("/")
      items = edition.fetch("items")
      base = Pathname(edition.fetch("package_dir"))
      candidates = [ Pathname(path).cleanpath.to_s, base.join(path).cleanpath.to_s ].uniq.filter_map { |key| items[key] }.uniq
      candidates.sole if candidates.one?
    end

    def write(candidate, time, attempt: 1)
      progress = @user.consumer_progresses.find_by(book: @book)
      same_place = progress && progress.asset_id == candidate["asset_id"] && progress.locator == candidate["locator"]
      if progress
        return candidate.merge("status" => "needs_choice", "reason" => "saved_time_unknown") if progress.observed_at.nil? && !same_place
        return candidate.merge("status" => "superseded") if progress.observed_at && progress.observed_at > time
        return candidate.merge("status" => "needs_choice", "reason" => "same_time") if progress.observed_at == time && !same_place
        return candidate.merge("status" => "shared") if same_place && (progress.observed_at.nil? || progress.observed_at == time)
      end

      mutation = self.class.mutation_for(@delivery, candidate["asset_id"], candidate["observed_at"], candidate["locator"])
      Consumer::ProgressWriter.new(user: @user, book: @book).call(
        "asset_id" => candidate["asset_id"], "locator" => candidate["locator"], "expected_version" => progress&.version || 0,
        "client_mutation_id" => mutation, "observed_at" => candidate["observed_at"])
      candidate.merge("status" => "shared", "mutation_id" => mutation)
    rescue Consumer::ProgressWriter::Conflict
      # Another device saved a place in between: compare again once.
      attempt == 1 ? write(candidate, time, attempt: 2) : candidate.merge("status" => "needs_choice", "reason" => "concurrent")
    rescue Consumer::ProgressWriter::Invalid
      candidate.merge("status" => "edition_changed", "reason" => "not_a_current_asset")
    end

    # Mutations this reader wrote are kept across later notices, so its own
    # place is never mistaken for another device's and sent back to it.
    def save(bridge)
      mutations = Array(@delivery.progress_bridge&.fetch("mutations", nil))
      mutations = (mutations - [ bridge["mutation_id"] ] + [ bridge["mutation_id"] ]).last(MUTATION_HISTORY) if bridge["mutation_id"]
      bridge = bridge.except("source", "mutation_id").merge("checked_at" => Time.current.utc.iso8601(3))
      bridge["mutations"] = mutations if mutations.any?
      @delivery.update_columns(progress_bridge: bridge)
      bridge
    end
  end
end
