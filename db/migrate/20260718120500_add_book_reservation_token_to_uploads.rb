# frozen_string_literal: true

class AddBookReservationTokenToUploads < ActiveRecord::Migration[8.1]
  def change
    add_column :uploads, :book_reservation_token, :string
    add_index :uploads,
      :book_reservation_token,
      unique: true,
      where: "book_reservation_token IS NOT NULL",
      name: "index_uploads_on_book_reservation_token"
  end
end
