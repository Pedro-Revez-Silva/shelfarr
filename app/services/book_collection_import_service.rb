# frozen_string_literal: true

class BookCollectionImportService
  class Error < StandardError; end

  def self.call(source_id:)
    new(source_id: source_id).call
  end

  def initialize(source_id:)
    @source_id = source_id.to_s.strip
  end

  def call
    unless @source_id.match?(/\A[1-9]\d{0,9}\z/) && @source_id.to_i <= 2_147_483_647
      raise Error, "Enter a valid Hardcover series ID."
    end

    # Fetch the complete snapshot before opening a transaction. An interrupted
    # page or a provider cooldown must leave the previous collection intact.
    entries = HardcoverClient.series_books(@source_id)
    raise Error, "This series has no complete, individual books to add." if entries.empty?
    if entries.any? { |entry| !entry.id.to_s.match?(/\A[1-9]\d*\z/) || entry.title.blank? }
      raise Error, "Hardcover returned an incomplete book identity. Please try again later."
    end

    entries = entries.uniq { |entry| entry.id.to_s }
    title = entries.first.series_name.presence
    raise Error, "Hardcover did not return a series title." unless title

    BookCollection.transaction do
      # Acquire SQLite's writer lock before reading the existing snapshot.
      BookCollection.where(source: "hardcover", source_id: @source_id).update_all(updated_at: Time.current)
      collection = BookCollection.find_or_initialize_by(source: "hardcover", source_id: @source_id)
      collection.update!(title: title, author: entries.first.author, cover_url: entries.first.cover_url, synced_at: Time.current)
      positions = entries.group_by { |entry| normalized_position(entry.series_position) }
      membership_ids = entries.each_with_index.map do |entry, index|
        work = BookWork.find_or_initialize_by(source: "hardcover", source_id: entry.id.to_s)
        work.update!(title: entry.title, author: entry.author, cover_url: entry.cover_url,
          description: entry.description, release_year: entry.release_year)
        work.attach_existing_books!
        membership = collection.collection_memberships.find_or_initialize_by(book_work: work)
        key = normalized_position(entry.series_position)
        membership.update!(position: entry.series_position, sort_order: index,
          ambiguous: key.present? && positions.fetch(key).length > 1)
        membership.id
      end
      collection.collection_memberships.where.not(id: membership_ids).destroy_all
      collection
    end
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout
    raise Error, "The collection is being updated. Please try again."
  rescue ActiveRecord::StatementInvalid => e
    raise unless e.cause.is_a?(SQLite3::BusyException)

    raise Error, "The collection is being updated. Please try again."
  rescue HardcoverClient::Error
    raise Error, "Could not load the complete Hardcover series. Check the connection and try again later."
  end

  private

  def normalized_position(value)
    value = value.to_s.strip
    return if value.blank?

    BigDecimal(value).to_s("F")
  rescue ArgumentError
    value.downcase
  end
end
