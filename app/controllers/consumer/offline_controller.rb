# frozen_string_literal: true

# Deliberate offline reading and listening in the browser.
#
# The service worker and the offline shell are static and account-free: they
# carry no session, CSRF token or personal data, so the worker may cache them.
# Media is stored only after the reader chooses Download, by the page and in a
# cache bound to the account and deployment subpath. The JSON endpoints below
# are personal and never cached by the worker.
class Consumer::OfflineController < ApplicationController
  include ConsumerWebPublication

  WORKER_SOURCE = Rails.root.join("app/javascript/consumer_offline_worker.js")
  OFFLINE_FONTS = %w[Newsreader-Regular.ttf Newsreader-SemiBold.ttf].freeze
  MAX_PUBLICATIONS = 50

  allow_unauthenticated_access only: %i[worker shell]
  # The worker carries no personal data, so cross-origin script inclusion
  # protection (meant for JavaScript responses with secrets) does not apply.
  skip_after_action :verify_same_origin_request, only: :worker
  before_action :private_response, only: %i[account publications downloads]

  def shell
    headers["Cache-Control"] = "no-cache"
    render layout: "consumer_offline"
  end

  # The worker script names exactly the shell and assets it precaches. Its
  # bytes change whenever they do, which is how browsers notice an update.
  def worker
    source = File.read(WORKER_SOURCE)
    shell = render_to_string(:shell, layout: "consumer_offline", formats: [ :html ])
    assets = offline_asset_paths
    config = { version: Digest::SHA256.hexdigest([ source, shell, *assets ].join("\0")).first(24),
      shell: consumer_offline_shell_path, assets: assets }
    headers["Cache-Control"] = "no-cache"
    headers["X-Content-Type-Options"] = "nosniff"
    render plain: "self.SHELFARR_OFFLINE = #{config.to_json};\n#{source}", content_type: "text/javascript"
  end

  # The current account and a fresh form token, so an offline shell that is
  # back online can confirm who is signed in before syncing a saved place.
  def account
    render json: { account: Current.user.id.to_s, csrf_token: form_authenticity_token,
      session_max_age_days: SettingsService.get(:session_max_age_days, default: 30).to_i }
  end

  # Current editions and saved places for downloaded publications.
  def publications
    ids = params[:ids].is_a?(String) ? params[:ids].split(",").uniq : []
    if ids.empty? || ids.size > MAX_PUBLICATIONS || ids.any? { |id| !id.match?(/\A[1-9]\d{0,18}\z/) }
      return render json: { error: "invalid_publications" }, status: :unprocessable_entity
    end

    books = Book.acquired.where(book_type: Consumer::LibraryScope.types(nil, graphic: true), id: ids).to_a
    representations = Consumer::Publication.many(books, user: Current.user, routes: self, reader_formats: web_reader_formats)
    render json: { account: Current.user.id.to_s, missing: ids - books.map { |book| book.id.to_s },
      publications: books.map { |book| web_publication(book, representations.fetch(book)) } }
  end

  def downloads
    render layout: "consumer"
  end

  private

  # JSON callers get a status they can act on instead of the sign-in redirect.
  def request_authentication
    return super unless request.format.json?

    render json: { error: "signed_out" }, status: :unauthorized
  end

  def offline_asset_paths
    imports = JSON.parse(Rails.application.importmap.to_json(resolver: helpers)).fetch("imports").values
    # The PDF renderer's worker, fonts, CMaps and decoders are needed offline too.
    pdf = Consumer::LibraryHelper.pdf_resource_paths.map { |path| helpers.asset_path(path) }
    [ helpers.stylesheet_path("consumer"), *OFFLINE_FONTS.map { |font| helpers.asset_path(font) }, *imports, *pdf ].uniq
  end

  def private_response
    headers["Cache-Control"] = "private, no-store"
  end
end
