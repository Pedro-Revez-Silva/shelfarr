# frozen_string_literal: true

module WebPreview
  class KoboReaderJson
    def self.version(device)
      Digest::SHA256.hexdigest([ device.id, device.name, device.store_coexistence, device.share_progress, device.receive_progress, device.token_digest ].to_json)[0, 24]
    end

    def self.choice(delivery, progress)
      Digest::SHA256.hexdigest([ delivery.id, delivery.revision_id, delivery.reading_state, delivery.progress_bridge, delivery.progress_outbound, progress&.version, progress&.client_mutation_id ].to_json)[0, 24]
    end

    def initialize(device, view:)
      @device = device
      @view = view
    end

    def row
      {
        id: @device.id.to_s,
        name: @device.name,
        mode: @device.store_coexistence? ? "store_and_shelfarr" : "shelfarr_only",
        mode_label: @view.kobo_mode_label(@device),
        store_coexistence: @device.store_coexistence?,
        share_progress: @device.share_progress?,
        receive_progress: @device.receive_progress?,
        base_url: @device.base_url.to_s.sub(KoboDevice::CONNECTION_PATH, "/kobo/…"),
        last_sync_at: @device.last_sync_at&.iso8601(3),
        version: self.class.version(@device)
      }
    end

    def detail
      row.merge(store_status: store_status, placeholder_sign_in: placeholder_sign_in, store_endpoint: KoboDevice::STORE_ENDPOINT, deliveries: deliveries)
    end

    def setup(token)
      { endpoint: @device.endpoint(token), store_endpoint: KoboDevice::STORE_ENDPOINT }
    end

    private

    def store_status
      return unless @device.store_coexistence?

      notice(@view.kobo_store_status(@device))
    end

    def placeholder_sign_in
      return unless @device.placeholder_auth_at && !@device.store_coexistence?

      "This reader received Shelfarr's placeholder sign-in #{@view.time_ago_in_words(@device.placeholder_auth_at)} ago. After keeping the Kobo Store, Kobo may ask it to sign in again; use the same Kobo account."
    end

    def deliveries
      records = @device.kobo_deliveries.includes(:book, :kobo_account_book_file, kobo_account_book: { kobo_account: :user }).order(updated_at: :desc, id: :desc).to_a
      progresses = @device.user.consumer_progresses.where(book_id: records.filter_map(&:book_id)).index_by(&:book_id)
      records.map { |delivery| delivery(delivery, progresses[delivery.book_id]) }
    end

    def delivery(delivery, progress)
      place = @view.kobo_place_notice(delivery, progress) if @device.share_progress? || delivery.progress_bridge.present?
      outbound = @view.kobo_outbound_notice(delivery, progress) if @device.receive_progress? && !delivery.private_source? && delivery.book_id
      acquired = !delivery.private_source? && delivery.book&.acquired?
      {
        entitlement_id: delivery.entitlement_id,
        choice: self.class.choice(delivery, progress),
        title: delivery.publication&.fetch("title", nil).to_s,
        source: delivery.private_source? ? "kobo_account" : "library",
        link: link(delivery, acquired),
        status: status(delivery, acquired),
        edition: @view.kobo_edition_text(delivery),
        place: place && notice(place),
        outbound: outbound && notice(outbound),
        send_again: acquired ? { book_id: delivery.book_id.to_s, confirmation: @view.kobo_send_again_confirmation(delivery, @device) } : nil
      }
    end

    def link(delivery, acquired)
      if delivery.private_source?
        delivery.deliverable? ? { kind: "kobo_book", href: @view.kobo_account_book_path(delivery.kobo_account_book) } : nil
      elsif acquired
        { kind: "library", publication_id: delivery.book_id.to_s }
      end
    end

    def status(delivery, acquired)
      return "Shared Kobo book · #{@view.kobo_shared_delivery_text(delivery)}" if delivery.private_source?
      return "Source removed from library · copy on reader kept" unless acquired
      return "Download requested #{@view.time_ago_in_words(delivery.last_download_at)} ago" if delivery.last_download_at

      "Queued · waiting for download"
    end

    def notice(value)
      { tone: value.tone.to_s, text: value.text, choosable: value.choosable }
    end
  end
end
