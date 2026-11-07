# frozen_string_literal: true

class Consumer::ReadingStatus
  class Invalid < StandardError; end

  def self.set(user:, book:, status:)
    unless status.is_a?(String) && ConsumerReadingState.statuses.key?(status)
      raise Invalid, "Choose unread, in_progress, or finished"
    end

    # Status is a separate user choice: background position writes never undo it,
    # and marking unread or finished does not discard a saved place.
    state = user.consumer_reading_states.create_or_find_by!(book: book)
    state.with_lock { state.update!(status: status) }
    state
  end
end
