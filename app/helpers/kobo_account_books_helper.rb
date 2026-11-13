# frozen_string_literal: true

# Plain-language delivery states for private Kobo account titles. Each
# reason is specific, so an ineligible title explains itself instead of
# offering a button that would fail.
module KoboAccountBooksHelper
  Eligibility = Data.define(:tone, :label, :detail)

  ELIGIBILITY = {
    eligible: [ :ok, "DRM-free EPUB · can be sent", "Kobo lists a DRM-free EPUB for this purchase. Shelfarr can keep a private copy and send it to a Kobo reader." ],
    protected: [ :warning, "Protected by DRM · can't be sent", "Kobo only offers this book with DRM tied to the purchasing account. Shelfarr does not remove DRM or move licences between accounts, so it can only be read on the owner's own Kobo." ],
    unsupported_format: [ :warning, "Format not supported", "Kobo doesn't list a verified DRM-free EPUB for this title (for example only KEPUB, PDF, fixed-layout, or an unverified DRM label)." ],
    no_download: [ :warning, "No download offered", "Kobo didn't list a downloadable file for this title." ],
    subscription: [ :info, "Kobo Plus subscription · can't be shared", "Subscription titles belong to the subscriber's plan, not a purchase, so Shelfarr doesn't send them to other readers." ],
    preview: [ :info, "Preview or sample · can't be shared", "Previews and samples are not purchases, so Shelfarr doesn't send them." ],
    ownership_unknown: [ :info, "Ownership not stated · can't be sent", "Kobo didn't say how this title was obtained, so it isn't treated as a purchase." ],
    audiobook: [ :info, "Audiobook · not for Kobo readers", "Audiobooks can't be sent to an e-reader." ],
    archived: [ :info, "Removed from the Kobo library", "Kobo lists this title as removed from the account." ],
    unchecked: [ :info, "Not checked yet · refresh needed", "This catalogue entry was saved before Shelfarr checked download rights. The account owner can use Refresh catalogue to check it." ]
  }.freeze

  TONES = { ok: "text-green-300", warning: "text-amber-300", info: "text-gray-400", choice: "text-sky-300" }.freeze

  def kobo_book_eligibility(book)
    Eligibility.new(*ELIGIBILITY.fetch(book.delivery_eligibility))
  end

  def kobo_tone(tone)
    TONES.fetch(tone)
  end

  def kobo_owner_label(account, viewer)
    account.user_id == viewer.id ? "your Kobo account “#{account.name}”" : "#{account.user.name}'s Kobo account “#{account.name}”"
  end

  # Where a private delivery stands for one reader, from Shelfarr's side.
  def kobo_shared_delivery_text(delivery)
    return "Access ended · Shelfarr no longer offers it; a downloaded copy stays on the reader" unless delivery.deliverable?
    return "Download requested #{time_ago_in_words(delivery.last_download_at)} ago" if delivery.last_download_at

    "Queued · waiting for the reader's next sync"
  end
end
