# frozen_string_literal: true

class ConsumerReadingState < ApplicationRecord
  belongs_to :user
  belongs_to :book
  enum :status, { unread: 0, in_progress: 1, finished: 2 }
end
