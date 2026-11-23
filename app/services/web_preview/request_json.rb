# frozen_string_literal: true

module WebPreview
  class RequestJson
    ACTIVE_DOWNLOADS = %i[queued downloading paused].freeze
    DOWNLOAD_STATUSES = %w[queued downloading paused completed failed].freeze
    BOOK_TYPES = %w[ebook audiobook comicbook].freeze
    TEXT_LIMIT = 500
    EVENT_LIMIT = 10
    COPY_STRUCTURES = { single_file: "single_file", multi_file: "multi_file" }.freeze
    UNREADABLE_SCORING = { structure: nil, bitrate_kbps: nil, preference_adjustment: 0, size_limit: nil }.freeze

    def self.copies_revision(request)
      shown = [
        Request.where(id: request.id).pick(:status, :search_generation),
        request.search_results.order(:id).pluck(:id, :updated_at).map { |id, updated_at| [ id, updated_at.iso8601(6) ] },
        request.downloads.order(:id).pluck(:id, :status)
      ]
      Digest::SHA256.hexdigest(shown.to_json).first(32)
    end

    def initialize(request, viewer:, routes:, opens_in_browser:)
      @request = request
      @book = request.book
      @viewer = viewer
      @routes = routes
      @opens_in_browser = opens_in_browser
    end

    def summary
      value = {
        id: @request.id.to_s,
        status: @request.status,
        attention_needed: @request.attention_needed,
        title: @book.title.to_s,
        author: @book.author.presence,
        book_type: BOOK_TYPES.include?(@book.book_type) ? @book.book_type : "unknown",
        cover: { url: Consumer::SafeLink.call(@book.cover_url), style: BookPage.cover_style(@book.id.to_s) },
        download_percent: download_percent,
        created_at: @request.created_at.iso8601(3),
        updated_at: @request.updated_at.iso8601(3),
        completed_at: @request.completed_at&.iso8601(3),
        next_retry_at: @request.next_retry_at&.iso8601(3),
        library: library,
        book_page: BookPage.path_for(@book)
      }
      value[:requested_by] = { name: @request.user&.name.to_s, self: own? } if admin?
      value
    end

    def detail(store_offers:)
      value = summary.merge(
        attention_reason: admin? && @request.attention_needed ? @request.issue_description.to_s.first(TEXT_LIMIT).presence : nil,
        downloads: @request.downloads.order(id: :desc).map { |download| download_fields(download) },
        choice_needed: @request.needs_manual_selection?,
        notes: @request.notes.to_s.first(TEXT_LIMIT).presence,
        collection_title: @request.collection_title.to_s.first(TEXT_LIMIT).presence,
        retry_count: @request.retry_count.to_i,
        actions: actions,
        store_offers: @request.completed? ? [] : store_offers.filter_map { |offer| offer_fields(offer) }
      )
      admin? ? value.merge(copies: copies, events: events) : value
    end

    private

    def admin?
      @viewer.admin?
    end

    def own?
      @request.user_id == @viewer.id
    end

    def download_percent
      return unless @request.downloading?

      @request.downloads.select { |download| ACTIVE_DOWNLOADS.include?(download.status&.to_sym) }.filter_map(&:progress).max&.clamp(0, 100)
    end

    def library
      return unless @book.acquired?
      return { state: "unavailable" } unless Consumer::RequestView::READABLE_TYPES.include?(@book.book_type) && @opens_in_browser.call(@book)

      { state: "available", publication_id: @book.id.to_s }
    end

    def download_fields(download)
      status = DOWNLOAD_STATUSES.include?(download.status) ? download.status : "unknown"
      progress = %w[queued downloading].include?(status) && download.progress ? download.progress.clamp(0, 100) : nil
      { status: status, progress: progress }
    end

    def actions
      {
        cancel: own? && !@request.failed? && @request.can_be_cancelled?,
        remove: removal,
        retry: admin? && @request.can_retry?,
        search_again: admin? && @request.search_refresh_allowed?,
        manual_download: admin? && @request.manual_download_allowed?,
        replaces_library_file: @book.acquired?,
        upload_url: upload_url,
        download_url: @book.acquired? ? @routes.download_request_path(@request) : nil
      }
    end

    def removal
      return "admin_remove" if admin?
      return "delete_history" if own? && @request.can_delete_completed_history?

      nil
    end

    def upload_url
      return unless @request.upload_fulfillable? && (admin? || SettingsService.user_uploads_allowed?)

      admin? ? @routes.new_admin_upload_path(request_id: @request.id) : @routes.new_upload_path(request_id: @request.id)
    end

    def offer_fields(offer)
      url = Consumer::SafeLink.call(offer.storefront_url)
      return unless url

      {
        id: offer.id.to_s,
        title: offer.title.to_s,
        author: offer.author.presence,
        provider: offer.provider_name,
        drm: offer.drm_label,
        price: offer.display_price,
        formats: offer.format_labels,
        language: offer.language.present? ? (ReleaseParserService.language_info(offer.language)&.dig(:name) || offer.language) : nil,
        quoted_at: offer.quoted_at&.iso8601(3),
        url: url
      }
    end

    def copies
      revision = self.class.copies_revision(@request)
      candidates = @request.search_results.best_first.includes(:acquisition_provider).to_a
      {
        selectable: BookPage.choosing_allowed?(@request) && candidates.any?(&:downloadable?),
        revision: revision,
        looking_for: @request.language_display_name.to_s.first(TEXT_LIMIT),
        search_blocked: @request.search_refresh_allowed? ? nil : @request.search_refresh_blocked_message,
        candidates: candidates.map { |result| BookPage.candidate(result).merge(details: copy_details(result)) }
      }
    end

    def copy_details(result)
      {
        choice: copy_choice(result),
        indexer: (result.indexer.to_s.first(TEXT_LIMIT).presence unless result.indexer == result.source_display_name),
        seeders: count(result.seeders),
        leechers: count(result.leechers),
        score: result.confidence_score&.clamp(0, 100),
        high_confidence: result.high_confidence?,
        language_matches: result.language_matches_request?,
        **scoring_facts(result),
        manual_review: !result.auto_select_allowed_by_preferences?,
        blocklist_reason: result.blocklisted? ? result.blocklist_reason.to_s.first(TEXT_LIMIT).presence : nil,
        info_url: result.safe_info_url
      }
    end

    def scoring_facts(result)
      {
        structure: COPY_STRUCTURES[result.audiobook_structure],
        bitrate_kbps: count(result.audio_bitrate_kbps)&.nonzero?,
        preference_adjustment: result.preference_adjustment,
        size_limit: size_limit(result)
      }
    rescue NoMethodError, TypeError
      UNREADABLE_SCORING
    end

    def copy_choice(result)
      return "selected" if result.selected?
      return result.rejected? ? "skipped" : "no_link" unless result.downloadable?
      return "retry_anyway" if result.blocklisted?

      result.rejected? ? "select_instead" : "select"
    end

    def count(value)
      value.to_i if value.present? && value.to_i >= 0
    end

    def size_limit(result)
      return if result.file_size_adjustment.zero?

      { label: result.file_size_adjustment_label, explanation: result.file_size_limit_explanation }
    end

    def events
      @request.request_events.recent.limit(EVENT_LIMIT).map do |event|
        { title: @routes.helpers.diagnostic_event_title(event), message: @routes.helpers.diagnostic_event_message(event).first(TEXT_LIMIT).presence,
          level: event.level.to_s, at: event.updated_at.iso8601(3) }
      end
    end
  end
end
