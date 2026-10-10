# frozen_string_literal: true

module Hardcover
  # Reads a subscription's entries from Hardcover and records them as items.
  #
  # * A snapshot enumerates every entry (up to a bound). Drafts use it so the
  #   user can preview what is there before anything is requested.
  # * An incremental sync of a list or Want to Read shelf only asks for
  #   entries changed since the previous successful sync.
  # * Author syncs always re-read the catalog because release dates move.
  #
  # Entries that were already present when the baseline was taken are never
  # requested automatically. Failures leave existing items and the cursor
  # untouched so the next run retries the same window.
  class SubscriptionSync
    MAX_SNAPSHOT_PAGES = 10
    MAX_INCREMENTAL_PAGES = 5
    CURSOR_OVERLAP = 1.hour
    NEW_RELEASE_GRACE = 30.days

    Result = Data.define(:fetched, :created, :queued, :truncated)

    def self.call(subscription, mode: :scheduled)
      new(subscription, mode: mode).call
    end

    def initialize(subscription, mode: :scheduled)
      @subscription = subscription
      @mode = mode.to_sym
      @started_at = Time.current
    end

    def call
      entries, truncated = fetch_entries
      created, queued = record_entries(entries)
      finish!(entries.size, truncated)
      Result.new(fetched: entries.size, created: created, queued: queued, truncated: truncated)
    end

    private

    attr_reader :subscription, :mode, :started_at

    def snapshot?
      mode == :snapshot || subscription.draft? || subscription.author?
    end

    def background?
      mode == :scheduled
    end

    def fetch_entries
      case subscription.kind
      when "want_to_read"
        Credentials.with_connection(subscription.user.hardcover_connection) do |credential|
          user_id = subscription.user.hardcover_connection.hardcover_user_id
          unique(paginate { |offset, since| API.want_to_read(user_id, credential: credential, offset: offset, since: since, background: background?) })
        end
      when "list"
        with_list_credential do |credential|
          unique(paginate { |offset, since| API.list_books(subscription.hardcover_target_id, credential: credential, offset: offset, since: since, background: background?) })
        end
      when "author"
        Credentials.with_catalog(user: subscription.user) do |credential|
          raw, truncated = paginate(force_full: true) do |offset, _since|
            API.author_contributions(subscription.hardcover_target_id, credential: credential, offset: offset, background: background?)
          end
          catalog = AuthorCatalog.filter(raw)
          @exclusions = catalog.excluded
          [ catalog.entries, truncated ]
        end
      end
    end

    # A list owned by the user may be private, so their own connection is
    # preferred; public lists can also be read with the instance token.
    def with_list_credential(&block)
      connection = subscription.user.hardcover_connection
      if connection&.usable?
        Credentials.with_connection(connection, &block)
      else
        Credentials.with_catalog(user: subscription.user, &block)
      end
    end

    def paginate(force_full: false)
      since = force_full || snapshot? ? nil : incremental_since
      max_pages = since ? MAX_INCREMENTAL_PAGES : MAX_SNAPSHOT_PAGES
      entries = []
      truncated = false
      offset = 0

      max_pages.times do |index|
        page = yield(offset, since)
        entries.concat(page.entries)
        break unless page.has_more

        offset += API::PAGE_SIZE
        truncated = index == max_pages - 1
      end

      [ entries, truncated ]
    end

    def unique((entries, truncated))
      [ entries.uniq(&:id), truncated ]
    end

    def incremental_since
      anchor = subscription.sync_cursor_at || subscription.baseline_established_at
      anchor ? anchor - CURSOR_OVERLAP : nil
    end

    def record_entries(entries)
      created = 0
      queued = 0
      existing = subscription.items.where(hardcover_book_id: entries.map(&:id)).index_by(&:hardcover_book_id)

      HardcoverSubscriptionItem.transaction do
        entries.each do |entry|
          item = existing[entry.id]
          if item
            refresh_item!(item, entry)
          else
            state = initial_state_for(entry)
            subscription.items.create!(item_attributes(entry).merge(
              state: state,
              book_types: state == "queued" ? subscription.book_types : [],
              first_seen_at: started_at
            ))
            created += 1
            queued += 1 if state == "queued"
          end
        end
      end

      [ created, queued ]
    end

    def refresh_item!(item, entry)
      attrs = item_attributes(entry)
      # A book announced for a later date stays upcoming until it is out.
      attrs[:state] = "upcoming" if item.known? && entry.unreleased? && subscription.author?
      item.update!(attrs)
    end

    def initial_state_for(entry)
      return "upcoming" if entry.unreleased?
      return "known" if subscription.draft?

      new_entry?(entry) ? new_entry_state : "known"
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

    def finish!(count, truncated)
      attrs = {
        last_synced_at: started_at,
        consecutive_failures: 0,
        last_error: nil,
        entries_seen_count: snapshot? ? count : subscription.entries_seen_count
      }
      attrs[:entries_truncated] = truncated if snapshot?
      attrs[:exclusions] = @exclusions.transform_keys(&:to_s) if @exclusions
      # Any successful read completes a pending manual check too, even if that
      # request was folded into this run by the concurrency guard.
      attrs[:snapshot_state] = "ready"
      attrs[:snapshot_completed_at] = started_at if subscription.draft? || mode == :snapshot
      unless subscription.draft?
        attrs[:sync_cursor_at] = started_at
        attrs[:next_sync_at] = started_at + subscription.sync_interval
      end
      subscription.update!(attrs)
    end
  end
end
