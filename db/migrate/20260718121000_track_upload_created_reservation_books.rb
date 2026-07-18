# frozen_string_literal: true

class TrackUploadCreatedReservationBooks < ActiveRecord::Migration[8.1]
  def change
    add_column :uploads,
      :book_reservation_created_book,
      :boolean,
      default: false,
      null: false
  end
end
