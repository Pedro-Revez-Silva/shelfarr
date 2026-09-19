# frozen_string_literal: true

# A provider's underlying work, shared by its ebook and audiobook copies.
# ISBNs and edition IDs deliberately do not identify collection members.
class BookWork < ApplicationRecord
  has_many :books, dependent: :restrict_with_error
  has_many :collection_memberships, dependent: :restrict_with_error
  has_many :book_collections, through: :collection_memberships

  validates :source, inclusion: { in: %w[hardcover] }
  validates :source_id, presence: true, uniqueness: { scope: :source }, format: { with: /\A[1-9]\d*\z/ }
  validates :title, presence: true

  def work_id
    "#{source}:#{source_id}"
  end

  def attach_existing_books!
    # Reuse only a provider-confirmed identity. Similar titles, years, and ISBNs
    # alone cannot establish that two records represent the same work.
    Book.where(hardcover_id: source_id, book_work_id: nil).update_all(book_work_id: id)
  end

  def metadata_attrs
    {
      title: title, author: author, cover_url: cover_url,
      description: description, first_publish_year: release_year, content_kind: "book"
    }
  end
end
