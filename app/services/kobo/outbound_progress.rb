# frozen_string_literal: true

module Kobo
  # Sends the reader owner's Shelfarr place (web, Android and iOS) to a stock
  # Kobo that opted in, for the same edition Shelfarr delivered to it.
  #
  # A place is sent only for a library KEPUB this reader downloaded, which is
  # still the current consumer asset the place names. Its destination is a real
  # koboSpan of that file's chapter (see SpanIndex), never a constructed one.
  # The bookmark carries the place's original activity time; evaluation,
  # queuing, retries and syncs never stamp it with a new time.
  #
  # The place is offered at the next sync as a reading-state-only change
  # (ChangedReadingState) by advancing the delivery's sync revision while its
  # entitlement, revision and file stay the same, so nothing is re-announced or
  # downloaded again. GET state serves the same place. Whether it is still the
  # owner's current place, still opted in, and not older than a genuine Kobo
  # place is checked again whenever it is served.
  #
  # Every span sent is remembered, so the Kobo echoing it back is recognised by
  # ProgressBridge and never becomes new Shelfarr activity.
  class OutboundProgress
    MAX_PER_SYNC = 20
    SENT_HISTORY = 8
    SENDABLE = %w[queued sent].freeze
    class NothingToSend < StandardError; end

    class << self
      # Evaluates the device's changed Shelfarr places before a sync page is
      # computed, so a newly queued place is inside this sync's bounds.
      def refresh(device, only: nil, limit: MAX_PER_SYNC)
        return unless device.receive_progress?

        deliveries = only ? [ only ] : candidates(device).to_a
        deliveries = deliveries.select { |delivery| eligible?(delivery) }
        progresses = progresses_for(device, deliveries)
        pending = deliveries.select do |delivery|
          progress = progresses[delivery.book_id]
          progress && delivery.progress_outbound&.fetch("key", nil) != key(delivery, progress)
        end
        pending.first(limit).each { |delivery| new(delivery, progresses[delivery.book_id]).evaluate! }
      end

      def progresses_for(device, deliveries)
        ids = deliveries.filter_map(&:book_id)
        return {} if ids.empty?

        device.user.consumer_progresses.where(book_id: ids).index_by(&:book_id)
      end

      def candidates(device)
        device.kobo_deliveries.where(kobo_account_book_id: nil).where.not(book_id: nil)
      end

      # Private household copies have no library edition and never qualify.
      def eligible?(delivery)
        !delivery.private_source? && delivery.book_id.present?
      end

      # What the evaluation depends on. A change to any part re-evaluates it.
      def key(delivery, progress)
        [ progress.version, progress.client_mutation_id, delivery.revision_id, delivery.last_download_at.present?,
          delivery.progress_generation_ambiguous? ].join(":")
      end

      # The reading state to give the Kobo, and whether it is Shelfarr's place.
      def serve(delivery, progress)
        outbound = delivery.progress_outbound
        stored = delivery.reading_state
        return [ stored, false ] unless outbound && SENDABLE.include?(outbound["status"]) && current?(delivery, progress, outbound)

        bookmark = stored&.dig("CurrentBookmark")
        if kobo_reading?(delivery, bookmark)
          kobo_time = ProgressBridge.activity_time(bookmark["LastModified"])
          # A genuine Kobo place is replaced only when it is provably older:
          # a later one, or one without a usable time, keeps the Kobo's place.
          return [ stored, false ] unless kobo_time && Time.iso8601(kobo_time) <= Time.iso8601(outbound.fetch("bookmark_at"))
        end
        [ state(delivery, stored, outbound), true ]
      end

      # A place the Kobo reached itself: a location or a percentage that is
      # not an echo of one Shelfarr sent.
      def kobo_reading?(delivery, bookmark)
        bookmark.is_a?(Hash) && !echo?(delivery, bookmark) &&
          (bookmark["Location"].is_a?(Hash) || (bookmark["ProgressPercent"].is_a?(Numeric) && bookmark["ProgressPercent"].positive?))
      end

      def current?(delivery, progress, outbound)
        delivery.kobo_device.receive_progress? && eligible?(delivery) && delivery.deliverable? && progress &&
          progress.user_id == delivery.kobo_device.user_id && progress.book_id == delivery.book_id &&
          progress.version == outbound["progress_version"] && progress.client_mutation_id == outbound["progress_mutation_id"]
      end

      # Records that a sync or GET handed Shelfarr's place to the reader.
      def sent!(deliveries)
        now = Time.current.utc.iso8601(3)
        deliveries.each do |delivery|
          outbound = delivery.progress_outbound
          next unless outbound && outbound["status"] == "queued"

          delivery.update_columns(progress_outbound: outbound.merge("status" => "sent", "sent_at" => now))
        end
      end

      # Whether a Kobo bookmark names a span Shelfarr sent to this reader.
      def echo?(delivery, bookmark)
        location = bookmark["Location"] if bookmark.is_a?(Hash)
        return false unless location.is_a?(Hash) && location["Value"].is_a?(String) && location["Source"].is_a?(String)

        sent = delivery.progress_outbound&.fetch("sent", nil)
        return false unless sent.is_a?(Array)

        sent.any? { |entry| entry["span"] == location["Value"] && same_source?(location["Source"], entry) }
      end

      # Kobo's spelling of a resource names the ZIP path of a sent place,
      # directly or relative to the package directory.
      def same_source?(kobo_source, place)
        source = source_path(kobo_source.to_s)
        source.present? && (place["source"] == source || place["source"] == Pathname(place["package_dir"].to_s).join(source).cleanpath.to_s)
      end

      # Kobo spells a resource as a ZIP path, or after the book's content ID.
      def source_path(source)
        path = URI::DEFAULT_PARSER.unescape(source.sub(/[?#].*\z/, ""))
        return unless path.valid_encoding? && !path.match?(/[\x00-\x1f\\]/) && path.bytesize <= ProgressBridge::MAX_SOURCE_BYTES

        parts = path.split("!")
        path = parts.drop(1).reject(&:empty?).join("/") if parts.size > 1
        Pathname(path.delete_prefix("/")).cleanpath.to_s
      end

      def state(delivery, stored, outbound)
        at = outbound.fetch("bookmark_at")
        stored ||= {}
        status = stored["StatusInfo"]
        status = { "LastModified" => at, "Status" => "Reading", "TimesStartedReading" => 1 } unless status.is_a?(Hash) && status["Status"].present? && status["Status"] != "ReadyToRead"
        bookmark = { "LastModified" => at, "Location" => { "Type" => "KoboSpan", "Source" => outbound.fetch("source"), "Value" => outbound.fetch("span") },
          "ContentSourceProgressPercent" => outbound.fetch("chapter_percent"), "ProgressPercent" => outbound["percent"] }.compact
        { "EntitlementId" => delivery.entitlement_id, "Created" => delivery.created_at.utc.iso8601(3),
          "LastModified" => at, "PriorityTimestamp" => at, "StatusInfo" => status,
          "Statistics" => stored["Statistics"].is_a?(Hash) ? stored["Statistics"] : { "LastModified" => at },
          "CurrentBookmark" => bookmark }
      end
    end

    def initialize(delivery, progress)
      @delivery = delivery
      @device = delivery.kobo_device
      @book = delivery.book
      @progress = progress
    end

    def evaluate!
      result = evaluate
      result["status"] == "queued" ? queue!(result) : record(result)
    rescue StandardError => error
      # The sync must still succeed. Never log the place, the path or the file.
      Rails.logger.warn("[Kobo] Shelfarr place not sent (#{error.class.name})")
      record(base.merge("status" => "unavailable"))
    end

    # The owner chose to send Shelfarr's place although it could not be
    # compared automatically. That choice is new activity, so the bookmark
    # carries the time of the choice; Shelfarr's own progress is unchanged.
    def choose!
      outbound = @delivery.progress_outbound || {}
      unless outbound["status"] == "needs_choice" && outbound["span"] && @progress &&
          outbound["key"] == self.class.key(@delivery, @progress) && @device.receive_progress? && self.class.eligible?(@delivery)
        raise NothingToSend
      end

      queue!(outbound.merge("status" => "queued", "reason" => "chosen", "bookmark_at" => Time.current.utc.iso8601(3))) || raise(NothingToSend)
    end

    private

    def base
      previous = @delivery.progress_outbound || {}
      { "key" => self.class.key(@delivery, @progress), "progress_version" => @progress.version,
        "progress_mutation_id" => @progress.client_mutation_id, "observed_at" => @progress.observed_at&.utc&.iso8601(3),
        "sent" => previous["sent"].is_a?(Array) ? previous["sent"] : [] }.compact
    end

    def evaluate
      result = base
      return result.merge("status" => "unsupported", "reason" => "not_an_ebook") unless @book&.ebook? && @progress.locator.is_a?(Hash)
      # This reader's own place, shared through ProgressBridge, is not sent back.
      return result.merge("status" => "kobo_place") if ProgressBridge.written_by?(@delivery, @progress)
      return result.merge("status" => "unsupported", "reason" => "plain_epub") unless @delivery.publication&.fetch("format", nil) == "KEPUB"
      return result.merge("status" => "waiting", "reason" => "not_downloaded") if @delivery.last_download_at.nil?

      place = destination
      return result.merge(place) if place["status"]

      candidate = result.merge(place)
      return candidate.merge("status" => "needs_choice", "reason" => "edition_unverified") if @delivery.progress_generation_ambiguous?
      return candidate.merge("status" => "needs_choice", "reason" => "unknown_time") unless candidate["observed_at"]

      compare(candidate)
    end

    # The span of the place in the exact delivered generation, if the place
    # names that generation as the current consumer asset.
    def destination
      file = @delivery.open_file
      stat = file.stat
      matches = Consumer::LibraryAssets.new(@book).list.select do |asset|
        asset.device == stat.dev && asset.inode == stat.ino && asset.size_bytes == stat.size
      end
      return { "status" => "unsupported", "reason" => "file_changed" } unless matches.one?
      return { "status" => "unsupported", "reason" => "different_edition" } unless matches.first.id == @progress.asset_id

      publication = KoboPublication.new(@book)
      order = publication.reading_order(file)
      path = chapter_path(@progress.locator["href"], order)
      return { "status" => "unsupported", "reason" => "location_not_in_edition" } unless path

      chapter = order.fetch("items").keys.index(path)
      place = SpanIndex.new(publication.resource(file, path, limit: SpanIndex::MAX_BYTES)).locate(@progress.locator, spine_index: chapter)
      total = @progress.locator.dig("locations", "totalProgression")
      { "asset_id" => matches.first.id, "source" => path, "package_dir" => order.fetch("package_dir"), "span" => place.span,
        "method" => place.method, "chapter" => chapter + 1, "chapters" => order.fetch("items").size,
        "chapter_percent" => (place.fraction * 100).round,
        "percent" => total.is_a?(Numeric) && total.finite? && total.between?(0, 1) ? (total * 100).round : nil }.compact
    rescue SpanIndex::Unsupported => error
      { "status" => "unsupported", "reason" => error.reason }
    rescue KoboPublication::TooLarge
      { "status" => "unsupported", "reason" => "chapter_too_large" }
    rescue KoboPublication::Unavailable, Consumer::LibraryAssets::Unavailable
      { "status" => "unsupported", "reason" => "file_changed" }
    ensure
      file&.close unless file&.closed?
    end

    # Shelfarr locators use the manifest's ZIP-root spelling of a spine item.
    def chapter_path(href, order)
      return unless href.is_a?(String) && href.bytesize <= 2048

      path = URI::DEFAULT_PARSER.unescape(href.sub(/[?#].*\z/, ""))
      return unless path.valid_encoding? && !path.match?(/[\x00-\x1f\\]/)

      path = Pathname(path).cleanpath.to_s
      path if order.fetch("items").key?(path)
    end

    # The Kobo's last uploaded place, unless it is an echo of Shelfarr's own.
    def compare(candidate)
      bookmark = @delivery.reading_state&.dig("CurrentBookmark")
      return queued(candidate) unless self.class.kobo_reading?(@delivery, bookmark)

      location = bookmark["Location"]
      if location.is_a?(Hash) && location["Value"] == candidate["span"] && self.class.same_source?(location["Source"], candidate)
        return candidate.merge("status" => "at_place")
      end

      kobo_time = ProgressBridge.activity_time(bookmark["LastModified"])
      return candidate.merge("status" => "needs_choice", "reason" => "kobo_time_unknown") unless kobo_time

      observed = Time.iso8601(candidate["observed_at"])
      kobo_time = Time.iso8601(kobo_time)
      return candidate.merge("status" => "needs_choice", "reason" => "kobo_newer", "kobo_at" => kobo_time.utc.iso8601(3)) if kobo_time > observed
      return candidate.merge("status" => "needs_choice", "reason" => "same_time") if kobo_time == observed

      queued(candidate)
    end

    def queued(candidate)
      candidate.merge("status" => "queued", "bookmark_at" => candidate.fetch("observed_at"))
    end

    # Advances the reader's sync revision under its lock, as publication does,
    # so an incremental cursor never skips this change. The progress is read
    # again inside the lock: a newer place re-evaluates at the next sync.
    def queue!(outbound)
      @device.with_lock do
        current = @device.user.consumer_progresses.find_by(book_id: @delivery.book_id)
        delivery = @device.kobo_deliveries.find(@delivery.id)
        unless current && current.version == outbound["progress_version"] && current.client_mutation_id == outbound["progress_mutation_id"] &&
            delivery.revision_id == @delivery.revision_id
          return
        end
        # A concurrent sync already queued this exact place: no second revision.
        previous = delivery.progress_outbound
        if previous && SENDABLE.include?(previous["status"]) && previous.values_at("key", "span", "bookmark_at") == outbound.values_at("key", "span", "bookmark_at")
          return @delivery.progress_outbound = previous
        end

        @device.increment(:sync_revision)
        @device.save!
        entry = outbound.slice("source", "span", "package_dir")
        sent = ((outbound["sent"] || []).reject { |item| item.slice("source", "span") == entry.slice("source", "span") } + [ entry ]).last(SENT_HISTORY)
        delivery.update_columns(sync_revision: @device.sync_revision, progress_outbound: outbound.merge("sent" => sent,
          "queued_at" => Time.current.utc.iso8601(3), "checked_at" => Time.current.utc.iso8601(3)))
        @delivery.progress_outbound = delivery.progress_outbound
        @delivery.sync_revision = delivery.sync_revision
      end
      @delivery.progress_outbound
    end

    def record(result)
      result = result.merge("checked_at" => Time.current.utc.iso8601(3))
      @delivery.update_columns(progress_outbound: result)
      result
    end
  end
end
