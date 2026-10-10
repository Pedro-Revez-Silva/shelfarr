# frozen_string_literal: true

module HardcoverHelper
  FORMAT_STATUS_LABELS = {
    acquired: "In library",
    requested: "Requested",
    available: "Not requested"
  }.freeze

  ITEM_STATE_CLASSES = {
    "known" => "bg-gray-800 text-gray-300",
    "pending" => "bg-blue-500/20 text-blue-300",
    "queued" => "bg-indigo-500/20 text-indigo-300",
    "requested" => "bg-green-500/20 text-green-300",
    "upcoming" => "bg-amber-500/20 text-amber-300",
    "failed" => "bg-red-500/20 text-red-300",
    "ignored" => "bg-gray-800 text-gray-500"
  }.freeze

  # Ownership is tracked per format: owning the ebook says nothing about the
  # audiobook, so each format gets its own status.
  def hardcover_format_statuses(work_id, existing_books_lookup, book_types: RequestOptionPolicy.book_types_for(ContentKinds::BOOK))
    book_types.to_h do |book_type|
      book = Book.find_in_lookup(existing_books_lookup, [ work_id ], book_type: book_type)
      status = if book&.acquired?
        :acquired
      elsif book&.requests&.any?(&:open?)
        :requested
      else
        :available
      end
      [ book_type, status ]
    end
  end

  def hardcover_format_status_class(status)
    case status
    when :acquired then "border-green-700/60 bg-green-900/30 text-green-300"
    when :requested then "border-blue-700/60 bg-blue-900/30 text-blue-300"
    else "border-gray-700 bg-gray-900 text-gray-400"
    end
  end

  def hardcover_item_state_class(state)
    ITEM_STATE_CLASSES.fetch(state.to_s, "bg-gray-800 text-gray-300")
  end

  def hardcover_attribution(url: "https://hardcover.app", text: "Book data from Hardcover")
    link_to text, url, target: "_blank", rel: "noopener", class: "text-xs text-gray-500 underline decoration-gray-700 underline-offset-2 hover:text-gray-300"
  end

  def hardcover_sync_status(subscription)
    if subscription.paused?
      "Paused#{": #{subscription.pause_reason}" if subscription.pause_reason.present?}"
    elsif subscription.draft?
      "Preview — nothing is requested until you confirm"
    elsif subscription.last_error.present?
      "Last check failed: #{subscription.last_error}"
    elsif subscription.last_synced_at
      "Checked #{time_ago_in_words(subscription.last_synced_at)} ago"
    else
      "Waiting for the first check"
    end
  end
end
