# frozen_string_literal: true

class WebPreview::OfflineWorkerController < ApplicationController
  include WebPreviewReaderShells

  SOURCE = Rails.root.join("apps/server/internal/gohttp/offline_worker.js")
  PRECACHED = %w[web/preview.js web/preview.css Newsreader-Regular.ttf Newsreader-SemiBold.ttf consumer_reader_engine.js].freeze
  POLICY = "default-src 'none'; connect-src 'self'"

  allow_unauthenticated_access
  skip_after_action :verify_same_origin_request

  def show
    return head :not_found unless WebPreview::Access.current.configured?

    headers["Cache-Control"] = "no-cache"
    headers["Content-Security-Policy"] = POLICY
    headers["Cross-Origin-Resource-Policy"] = "same-origin"
    headers["X-Content-Type-Options"] = "nosniff"
    render plain: "self.SHELFARR_GO_OFFLINE = #{worker_config.to_json};\n#{SOURCE.read}", content_type: "text/javascript"
  end

  private

  def worker_config
    config = { library: web_preview_library_path, downloads: web_preview_downloads_path, assets: precached_assets,
      shells: TITLES.keys.index_with { |view| { body: reader_shell_document(view), headers: reader_shell_headers(view) } } }
    { version: Digest::SHA256.hexdigest(config.to_json + SOURCE.read).first(24), **config }
  end

  def precached_assets
    PRECACHED.map { |logical| { path: helpers.asset_path(logical), sha256: Digest::SHA256.hexdigest(served_bytes(logical)) } }
  end

  def served_bytes(logical)
    asset = Rails.application.assets.load_path.find(logical)
    precompiled = Pathname(Rails.application.assets.config.output_path).join(asset.digested_path)
    precompiled.file? ? precompiled.binread : asset.compiled_content
  end
end
