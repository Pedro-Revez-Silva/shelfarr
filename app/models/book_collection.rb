# frozen_string_literal: true

class BookCollection < ApplicationRecord
  has_many :collection_memberships, -> { order(:sort_order, :id) }, dependent: :destroy
  has_many :book_works, through: :collection_memberships

  validates :source, inclusion: { in: %w[hardcover] }
  validates :source_id, presence: true, uniqueness: { scope: :source }, format: { with: /\A[1-9]\d*\z/ }
  validates :title, presence: true
end
