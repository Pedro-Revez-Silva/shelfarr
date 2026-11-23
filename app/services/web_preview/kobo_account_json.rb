# frozen_string_literal: true

module WebPreview
  class KoboAccountJson
    ACTIVATION_PAGE = "https://www.kobo.com/activate"

    def self.version(account, share_ids = account.kobo_account_shares.ids)
      Digest::SHA256.hexdigest([ account.id, account.name, account.status, share_ids.sort ].to_json)[0, 24]
    end

    def self.copy_version(file)
      file && Digest::SHA256.hexdigest([ file.id, file.sha256 ].to_json)[0, 24]
    end

    def initialize(viewer, view:)
      @viewer = viewer
      @view = view
    end

    def row(account)
      { id: account.id.to_s, name: account.name, state: state(account), status_label: status_label(account), shared_with: account.kobo_account_shares.size }
    end

    def received(share, sendable_count)
      account = share.kobo_account
      { id: account.id.to_s, name: account.name, owner_name: account.user.name, sendable_count: sendable_count }
    end

    def detail(account)
      shares = account.kobo_account_shares.includes(:recipient).order(:created_at).to_a
      linked = state(account).in?(%w[connected reauthorization_required])
      row(account).merge(
        shared_with: shares.size,
        version: self.class.version(account, shares.map(&:id)),
        error: account.error_message,
        activation: activation(account),
        kobo_email: linked ? account.kobo_email : nil,
        refreshing: linked && account.sync_active?,
        can_refresh: account.connected? && !account.sync_active?,
        last_synced_at: linked ? account.last_synced_at&.iso8601(3) : nil,
        sharing: linked ? sharing(account, shares) : nil
      )
    end

    def catalogue(account, books:, filter:, page:, more:, count:, sendable_count:)
      {
        kobo_account: { id: account.id.to_s, name: account.name, owner: account.user_id == @viewer.id, owner_name: account.user.name,
          connected: account.connected?, last_synced_at: account.last_synced_at&.iso8601(3) },
        filter: filter,
        page: page,
        more: more,
        count: count,
        sendable_count: sendable_count,
        books: books.map { |book| catalogue_entry(book) }
      }
    end

    def book(book, grant)
      account = book.kobo_account
      eligibility = @view.kobo_book_eligibility(book)
      file = book.ready_file
      {
        id: book.id.to_s,
        title: book.title,
        author: book.author.presence,
        from: @view.kobo_owner_label(account, @viewer),
        kobo_account: { id: account.id.to_s, name: account.name, owner: grant.owner?, owner_name: account.user.name },
        cover: file ? @view.cover_kobo_account_book_path(book) : nil,
        eligibility: { tone: eligibility.tone.to_s, label: eligibility.label, detail: eligibility.detail },
        deliverable: book.deliverable?,
        offered: book.deliverable? && book.download_size ? "#{book.download_format} · #{@view.number_to_human_size(book.download_size)} according to Kobo" : nil,
        copy: book.deliverable? ? copy(book, account, grant, file) : nil,
        readers: book.deliverable? ? readers(book, file) : []
      }
    end

    private

    def state(account)
      return "pending" if account.pending?
      return account.status if account.connected? || account.status == "reauthorization_required"

      "incomplete"
    end

    def status_label(account)
      account.connected? ? "Connected" : "Sign-in #{account.status.humanize.downcase}"
    end

    def activation(account)
      return unless account.pending?

      { code: account.activation_code, page: ACTIVATION_PAGE, expires_at: account.activation_expires_at.iso8601(3) }
    end

    def sharing(account, shares)
      taken = [ @viewer.id, *shares.map(&:recipient_id) ]
      {
        people: shares.map do |share|
          { id: share.id.to_s, name: share.recipient.name, username: share.recipient.username, shared_at: share.created_at.iso8601(3), inactive: share.recipient.deleted? }
        end,
        candidates: User.active.where.not(id: taken).order(:name, :username).map { |user| { id: user.id.to_s, label: "#{user.name} (#{user.username})" } }
      }
    end

    def catalogue_entry(book)
      eligibility = @view.kobo_book_eligibility(book)
      { id: book.id.to_s, title: book.title, author: book.author.presence, eligibility: { tone: eligibility.tone.to_s, label: eligibility.label } }
    end

    def copy(book, account, grant, file)
      fetch = book.active_fetch
      failure = book.latest_failure
      failure = nil unless failure && (file.nil? || failure.updated_at > file.fetched_at)
      {
        version: self.class.copy_version(file),
        preparing: fetch.present?,
        failure: failure&.error_message,
        ready: file ? ready(file) : nil,
        unavailable: unavailable(account, grant, file, fetch),
        explanation: explanation(account, grant, file, fetch)
      }
    end

    def ready(file)
      version = " #{file.epub_version}" if file.epub_version.present?
      { summary: "#{file.format || 'EPUB'}#{version}, #{@view.number_to_human_size(file.size_bytes)}", prepared_at: file.fetched_at.iso8601(3), stale: file.stale? }
    end

    def unavailable(account, grant, file, fetch)
      return if fetch || file || account.connected?

      grant.owner? ? "Reconnect this Kobo account to prepare a copy." : "#{account.user.name} needs to reconnect this Kobo account before a copy can be prepared."
    end

    def explanation(account, grant, file, fetch)
      return if fetch || file || !account.connected?

      owner = grant.owner?
      "Shelfarr first saves a private copy of the DRM-free EPUB on this server, using #{owner ? 'your' : "#{account.user.name}'s"} Kobo connection. " \
        "#{'Nobody else sees the sign-in. ' unless owner}The copy is checked before it can be sent and stays out of the shared library."
    end

    def readers(book, file)
      devices = @viewer.kobo_devices.order(:name, :id).to_a
      deliveries = KoboDelivery.where(kobo_account_book: book, kobo_device: devices).index_by(&:kobo_device_id)
      devices.map do |device|
        delivery = deliveries[device.id]
        {
          id: device.id.to_s,
          name: device.name,
          status: delivery ? @view.kobo_shared_delivery_text(delivery) : @view.kobo_mode_label(device),
          older_copy: delivery.present? && file.present? && delivery.kobo_account_book_file_id != file.id,
          sent: delivery.present?
        }
      end
    end
  end
end
