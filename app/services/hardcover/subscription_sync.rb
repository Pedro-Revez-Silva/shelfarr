# frozen_string_literal: true

module Hardcover
  # Reads a subscription's entries from Hardcover and records them as items.
  #
  # * A snapshot enumerates every entry (up to a bound). Drafts use it so the
  #   user can preview what is there before anything is requested.
  # * An incremental sync of a list or Want to Read shelf reads the entries
  #   changed in a fixed window since the previous complete sync. The window
  #   is read in pages by row id and its position is saved with every page,
  #   so a window larger than one run, an outage, or a restart continues
  #   where it stopped. The cursor only moves once the whole window is read.
  # * Author syncs re-read the newest part of the catalog every time, because
  #   release dates move, and work through longer catalogs a few pages a run.
  #
  # Entries that were already present when the baseline was taken are never
  # requested automatically. Every write first checks that the subscription
  # still follows the same account (its sync generation), so a sync that
  # started before the account changed discards what it read.
  class SubscriptionSync
    MAX_SNAPSHOT_PAGES = 10
    MAX_INCREMENTAL_PAGES = 5
    AUTHOR_CATALOG_PAGES = 2
    CURSOR_OVERLAP = 1.hour
    NEW_RELEASE_GRACE = 30.days

    # The subscription was removed or now follows another account.
    class Stale < StandardError; end

    Result = Data.define(:fetched, :created, :queued, :truncated, :continuing)

    def self.call(subscription, mode: :scheduled)
      new(subscription, mode: mode).call
    end

    def initialize(subscription, mode: :scheduled)
      @subscription = subscription
      @mode = mode.to_sym
      @started_at = Time.current
      @generation = subscription.sync_generation
      @created = 0
      @queued = 0
    end

    def call
      if subscription.author?
        sync_author
      elsif incremental?
        sync_incremental
      else
        sync_snapshot
      end
    end

    private

    attr_reader :subscription, :mode, :started_at, :generation

    def snapshot?
      mode == :snapshot || subscription.draft?
    end

    def incremental?
      !snapshot? && (subscription.catching_up? || incremental_since.present?)
    end

    def background?
      mode == :scheduled
    end

    def sync_snapshot
      entries = []
      truncated = false
      with_entry_reader do |read|
        entries, truncated = read_offset_pages { |offset| read.call(offset: offset) }
      end
      entries = entries.uniq(&:id)
      progress = subscription.draft? ? {} : { sync_cursor_at: started_at, sync_window_since: nil, sync_window_until: nil, sync_window_before_id: nil }
      record!(entries, progress)
      finish!(fetched: entries.size, entries_seen: entries.size, truncated: truncated)
    end

    def sync_incremental
      window = open_window
      fetched = 0
      drained = false
      with_entry_reader do |read|
        MAX_INCREMENTAL_PAGES.times do
          page = read.call(since: window[:since], before_id: window[:before_id])
          fetched += page.entries.size
          # A full page always carries row ids; without one the position
          # cannot be saved, so stop rather than skip what follows.
          raise HardcoverClient::Error, "Hardcover returned a page without row ids" if page.has_more && page.next_cursor.blank?

          continuing = page.has_more
          if continuing
            window[:before_id] = page.next_cursor
            progress = { sync_window_since: window[:since], sync_window_until: window[:until], sync_window_before_id: window[:before_id] }
          else
            # The whole window was read; the next one starts where it ended.
            progress = { sync_cursor_at: window[:until], sync_window_since: nil, sync_window_until: nil, sync_window_before_id: nil }
          end
          record!(page.entries.uniq(&:id), progress)
          next if continuing

          drained = true
          break
        end
      end
      finish!(fetched: fetched, continuing: !drained)
    end

    # The newest and upcoming releases are read every time. When the catalog
    # is longer than that scan, a few more pages of the rest are read in id
    # order, continuing from the previous run and starting over at the end.
    def sync_author
      raw = []
      rolling = []
      truncated = false
      cursor = nil
      Credentials.with_catalog(user: subscription.user) do |credential|
        raw, truncated = read_offset_pages do |offset|
          API.author_contributions(subscription.hardcover_target_id, credential: credential, offset: offset, background: background?)
        end
        rolling, cursor = read_author_catalog(credential) if truncated && !subscription.draft?
      end

      recent = AuthorCatalog.filter(raw)
      catalog = rolling.any? ? AuthorCatalog.filter(raw + rolling) : recent
      @exclusions = recent.excluded
      record!(catalog.entries, catalog_cursor_id: cursor)
      finish!(fetched: catalog.entries.size, entries_seen: recent.entries.size, truncated: truncated)
    end

    def read_author_catalog(credential)
      entries = []
      cursor = subscription.catalog_cursor_id.to_i
      AUTHOR_CATALOG_PAGES.times do
        page = API.author_catalog_contributions(subscription.hardcover_target_id, credential: credential, after_id: cursor, background: background?)
        entries.concat(page.entries)
        if page.has_more && page.next_cursor
          cursor = page.next_cursor
        else
          cursor = 0
          break
        end
      end
      [ entries, cursor ]
    end

    def with_entry_reader
      if subscription.want_to_read?
        connection = owner_connection!
        account_id = subscription.hardcover_account_id
        Credentials.with_connection(connection, account_id: account_id) do |credential|
          yield ->(offset: 0, since: nil, before_id: nil) do
            API.want_to_read(account_id, credential: credential, offset: offset, since: since, before_id: before_id, background: background?)
          end
        end
      else
        with_list_credential do |credential, public_only|
          yield ->(offset: 0, since: nil, before_id: nil) do
            API.list_books(subscription.hardcover_target_id, credential: credential, offset: offset, since: since,
              before_id: before_id, background: background?, public_only: public_only)
          end
        end
      end
    end

    # A private list is only read with its owner's own connection. Other
    # lists are read as public data, with the follower's connection when
    # they have one (their own budget) or the instance token.
    def with_list_credential
      if subscription.personal?
        connection = owner_connection!
        return Credentials.with_connection(connection, account_id: subscription.hardcover_account_id) { |credential| yield credential, false }
      end

      connection = subscription.user.hardcover_connection
      if connection&.usable?
        owner = subscription.owned_by_connection?(connection)
        Credentials.with_connection(connection, account_id: connection.hardcover_user_id) { |credential| yield credential, !owner }
      else
        Credentials.with_catalog(user: subscription.user) { |credential| yield credential, true }
      end
    end

    def owner_connection!
      connection = subscription.user.hardcover_connection
      raise Credentials::Unavailable, "Connect your Hardcover account first." unless connection&.usable?
      raise Credentials::AccountMismatch, HardcoverSubscription::PAUSE_OTHER_ACCOUNT unless subscription.owned_by_connection?(connection)

      connection
    end

    def read_offset_pages
      entries = []
      truncated = false
      offset = 0

      MAX_SNAPSHOT_PAGES.times do |index|
        page = yield(offset)
        entries.concat(page.entries)
        break unless page.has_more

        offset += API::PAGE_SIZE
        truncated = index == MAX_SNAPSHOT_PAGES - 1
      end

      [ entries, truncated ]
    end

    def open_window
      if subscription.catching_up?
        {
          since: subscription.sync_window_since || incremental_since,
          until: subscription.sync_window_until,
          before_id: subscription.sync_window_before_id
        }
      else
        { since: incremental_since, until: started_at, before_id: nil }
      end
    end

    def incremental_since
      anchor = subscription.sync_cursor_at || subscription.baseline_established_at
      anchor ? anchor - CURSOR_OVERLAP : nil
    end

    # Records one batch of entries together with the sync's progress, so the
    # saved position always matches the saved items.
    def record!(entries, progress = {})
      HardcoverSubscription.transaction do
        ensure_current!
        existing = subscription.items.where(hardcover_book_id: entries.map(&:id)).index_by(&:hardcover_book_id)
        entries.each do |entry|
          item = existing[entry.id]
          item ? refresh_item!(item, entry) : create_item!(entry)
        end
        subscription.update!(progress) if progress.any?
      end
    end

    def ensure_current!
      current = HardcoverSubscription.lock.find_by(id: subscription.id)
      raise Stale, "Hardcover subscription #{subscription.id} changed during the sync" unless current && current.sync_generation == generation

      # Settings changed while Hardcover was being read apply to what is
      # recorded now, so turning automatic requests off stops queueing.
      subscription.automatic = current.automatic
      subscription.book_types = current.read_attribute(:book_types)
    end

    def create_item!(entry)
      new_entry = !subscription.draft? && new_entry?(entry)
      state = if entry.unreleased? then "upcoming"
      elsif new_entry then new_entry_state
      else "known"
      end
      subscription.items.create!(item_attributes(entry).merge(
        state: state,
        # Remembered separately from the state: a book that was already on a
        # list or shelf stays out of automatic requests after its release.
        baseline: baseline_entry?(entry, new_entry),
        book_types: state == "queued" ? subscription.book_types : [],
        first_seen_at: started_at
      ))
      @created += 1
      @queued += 1 if state == "queued"
    end

    def refresh_item!(item, entry)
      attrs = item_attributes(entry)
      if entry.unreleased? && postponable?(item)
        # The release moved to a later date before anything was requested.
        # The book waits as upcoming, keeping the user's selection and
        # formats, and is evaluated again once it is out.
        attrs.merge!(state: "upcoming", claim_token: nil, claimed_at: nil, next_attempt_at: nil)
      elsif subscription.author? && item.known?
        if entry.unreleased?
          # A book announced for a later date stays upcoming until it is out.
          attrs[:state] = "upcoming"
        elsif !item.baseline? && item.release_date.nil? && new_entry?(entry)
          # First seen without a date after the baseline, now dated as a new
          # release.
          attrs[:state] = new_entry_state
          attrs[:book_types] = subscription.book_types if attrs[:state] == "queued"
          @queued += 1 if attrs[:state] == "queued"
        end
      end
      item.update!(attrs)
    end

    # Books waiting to be requested. A book already requested keeps its
    # requests whatever its date says.
    def postponable?(item)
      item.pending? || item.queued? || item.failed?
    end

    # Whether an entry counts as already present. Everything in a preview
    # does, and so does an older entry found later. An author's book without
    # a release date is the exception: Hardcover often adds the date later,
    # so a book first seen after the baseline stays eligible to be judged
    # as a new release once its date is known (and stays backlist if that
    # date turns out to be old).
    def baseline_entry?(entry, new_entry)
      return true if subscription.draft?
      return false if new_entry

      !(subscription.author? && entry.release_date.nil?)
    end

    def new_entry?(entry)
      baseline = subscription.baseline_established_at
      return true unless baseline

      if subscription.author?
        # A record for an old book added to Hardcover later is backlist, not
        # a new release, so only recent release dates count as new.
        entry.release_date.present? && entry.release_date >= (baseline - NEW_RELEASE_GRACE).to_date
      else
        # Without a timestamp, leave the decision to the user.
        entry.added_at.nil? || entry.added_at >= baseline
      end
    end

    def new_entry_state
      subscription.automatic? && subscription.book_types.any? ? "queued" : "pending"
    end

    def item_attributes(entry)
      {
        hardcover_book_id: entry.id,
        title: entry.title.truncate(255),
        author: entry.author&.truncate(255),
        cover_url: entry.cover_url&.first(1000),
        description: entry.description,
        release_date: entry.release_date,
        release_year: entry.release_year || entry.release_date&.year,
        series_name: entry.series_name&.truncate(255),
        series_position: entry.series_position,
        users_count: entry.users_count,
        has_audiobook: entry.has_audiobook,
        has_ebook: entry.has_ebook,
        entry_added_at: entry.added_at,
        position: entry.position,
        last_seen_at: started_at
      }
    end

    def finish!(fetched:, entries_seen: nil, truncated: false, continuing: false)
      attrs = {
        last_synced_at: started_at,
        consecutive_failures: 0,
        last_error: nil,
        # Any successful read completes a pending manual check too, even if
        # that request was folded into this run by the concurrency guard.
        snapshot_state: "ready"
      }
      unless entries_seen.nil?
        attrs[:entries_seen_count] = entries_seen
        attrs[:entries_truncated] = truncated
      end
      attrs[:exclusions] = @exclusions.transform_keys(&:to_s) if @exclusions
      attrs[:snapshot_completed_at] = started_at if snapshot?
      # A window that is not finished continues on the next run right away.
      attrs[:next_sync_at] = continuing ? started_at : started_at + subscription.sync_interval unless subscription.draft?
      HardcoverSubscription.transaction do
        ensure_current!
        subscription.update!(attrs)
      end
      Result.new(fetched: fetched, created: @created, queued: @queued, truncated: truncated, continuing: continuing)
    end
  end
end
