# frozen_string_literal: true

class CollectionMembership < ApplicationRecord
  belongs_to :book_collection
  belongs_to :book_work

  validates :book_work_id, uniqueness: { scope: :book_collection_id }
  validates :sort_order, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
