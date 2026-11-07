# frozen_string_literal: true

class KoboDelivery < ApplicationRecord
  belongs_to :kobo_device
  belongs_to :book, optional: true

  def open_file
    raise KoboPublication::Unavailable, "This book is no longer in the library" unless book

    KoboPublication.new(book).open_file(expected_fingerprint: publication.fetch("fingerprint"))
  end
end
