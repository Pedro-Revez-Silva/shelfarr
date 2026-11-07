# frozen_string_literal: true

class KoboSync
  PAGE_SIZE = 100
  Result = Data.define(:items, :token, :more)

  def initialize(device, endpoint:)
    @device = device
    @endpoint = endpoint
  end

  def call(raw_cursor)
    after, upper, since = cursor_bounds(raw_cursor)
    deliveries = @device.kobo_deliveries.where(sync_revision: (after + 1)..upper).order(:sync_revision).limit(PAGE_SIZE + 1).to_a
    more = deliveries.size > PAGE_SIZE
    deliveries = deliveries.first(PAGE_SIZE)
    next_after = more ? deliveries.last.sync_revision : upper
    token = verifier.generate({ "device" => @device.id, "generation" => @device.token_digest,
      "after" => next_after, "upper" => more ? upper : nil, "since" => more ? since : next_after }, purpose: "kobo-sync")
    items = deliveries.map do |delivery|
      kind = delivery.first_revision > since || since.zero? ? "NewEntitlement" : "ChangedEntitlement"
      payload = { "BookEntitlement" => entitlement(delivery), "BookMetadata" => metadata(delivery) }
      payload["ReadingState"] = delivery.reading_state if delivery.reading_state
      { kind => payload }
    end
    @device.update_columns(last_sync_at: Time.current)
    Result.new(items: items, token: token, more: more)
  end

  def metadata(delivery)
    publication = delivery.publication
    id = delivery.entitlement_id
    formats = publication.fetch("format") == "KEPUB" ? [ "KEPUB" ] : [ "EPUB3", "EPUB" ]
    {
      "Categories" => [ "00000000-0000-0000-0000-000000000001" ],
      "CoverImageId" => id, "CrossRevisionId" => id, "EntitlementId" => id,
      "RevisionId" => delivery.revision_id, "WorkId" => id,
      "CurrentDisplayPrice" => { "CurrencyCode" => "USD", "TotalAmount" => 0 },
      "CurrentLoveDisplayPrice" => { "TotalAmount" => 0 },
      "Description" => publication.fetch("description"), "Title" => publication.fetch("title"),
      "Contributors" => [ publication["author"].presence || "Unknown" ],
      "ContributorRoles" => [ { "Name" => publication["author"].presence || "Unknown" } ],
      "DownloadUrls" => formats.map { |format| { "Format" => format, "Platform" => "Generic",
        "Size" => publication.fetch("size"), "Url" => "#{@endpoint}/download/#{id}/#{delivery.revision_id}" } },
      "ExternalIds" => [], "Genre" => "00000000-0000-0000-0000-000000000001",
      "IsEligibleForKoboLove" => false, "IsInternetArchive" => false,
      "IsPreOrder" => false, "IsSocialEnabled" => false, "Language" => "en",
      "PhoneticPronunciations" => {}, "PublicationDate" => timestamp(delivery.created_at),
      "Publisher" => { "Name" => "", "Imprint" => "" }
    }
  end

  private

  def cursor_bounds(raw)
    payload = verifier.verified(raw.to_s, purpose: "kobo-sync") if raw.to_s.bytesize < 4096
    if payload.is_a?(Hash) && payload["device"] == @device.id && payload["generation"] == @device.token_digest
      after = payload["after"]
      upper = payload["upper"] || @device.sync_revision
      since = payload["since"]
      if [ since, after, upper ].all? { |value| value.is_a?(Integer) } && 0 <= since && since <= after && after <= upper && upper <= @device.sync_revision
        return [ after, upper, since ]
      end
    end
    [ 0, @device.sync_revision, 0 ]
  end

  def verifier
    Rails.application.message_verifier("kobo-sync-v1")
  end

  def entitlement(delivery)
    { "Accessibility" => "Full", "ActivePeriod" => { "From" => timestamp(delivery.created_at) },
      "Created" => timestamp(delivery.created_at), "LastModified" => timestamp(delivery.updated_at),
      "CrossRevisionId" => delivery.entitlement_id, "Id" => delivery.entitlement_id,
      "RevisionId" => delivery.revision_id, "IsRemoved" => false,
      "IsHiddenFromArchive" => false, "IsLocked" => false,
      "OriginCategory" => "Imported", "Status" => "Active" }
  end

  def timestamp(value)
    value.utc.iso8601(3)
  end
end
