# frozen_string_literal: true

# Expands a collection request (a Comic Vine volume or Hardcover series) into
# individual requests. Collections can contain hundreds of items, so the
# expansion runs here instead of inside the web request that queued it.
class CollectionRequestExpansionJob < ApplicationJob
  queue_as :default

  retry_on MetadataCollectionService::Error, wait: :polynomially_longer, attempts: 3

  def perform(user_id:, work_id:, book_types:, metadata_attrs:, notes: nil, language: nil, origin: {}, source_work_ids: nil)
    user = User.find_by(id: user_id)
    if user.nil?
      Rails.logger.warn("[CollectionRequestExpansionJob] User #{user_id} no longer exists, skipping #{work_id}")
      return
    end

    result = RequestCreationService.call(
      user: user,
      work_id: work_id,
      book_types: book_types,
      metadata_attrs: metadata_attrs,
      notes: notes,
      language: language,
      origin: origin,
      source_work_ids: source_work_ids,
      expand_collection: true
    )

    summary = "created #{result.created_requests.size} requests for #{work_id}"
    if result.errors.any?
      Rails.logger.warn("[CollectionRequestExpansionJob] #{summary}, errors: #{result.errors.join('; ')}")
    else
      Rails.logger.info("[CollectionRequestExpansionJob] #{summary}")
    end
  end
end
