# frozen_string_literal: true

module WebPreviewReaderShells
  READER_POLICY = [
    "default-src 'none'", "script-src 'self'", "style-src 'self' 'unsafe-inline' blob:", "font-src 'self' blob: data:",
    "img-src 'self' https: blob: data:", "media-src 'self'", "connect-src 'self'", "frame-src 'self'", "manifest-src 'none'",
    "form-action 'none'", "base-uri 'self'", "frame-ancestors 'self'", "object-src 'none'"
  ].join("; ").freeze
  TITLES = { "reader" => "Reader · Shelfarr", "downloads" => "Downloads · Shelfarr" }.freeze
  COPIED_DEFAULT_HEADERS = %w[X-Content-Type-Options X-Frame-Options Referrer-Policy].freeze
  OFFLINE_CACHE = "shelfarr-rails-preview-offline.v1"

  private

  def reader_shell_document(view)
    render_to_string(template: "web_preview/shell/reader", layout: false, formats: [ :html ],
      locals: { title: TITLES.fetch(view), boot: reader_shell_boot(view) })
  end

  def reader_shell_headers(view)
    Rails.application.config.action_dispatch.default_headers.to_h.slice(*COPIED_DEFAULT_HEADERS).merge(
      "Content-Type" => "text/html; charset=utf-8",
      "Content-Security-Policy" => view == "reader" ? READER_POLICY : WebPreview::ShellController::CONTENT_SECURITY_POLICY,
      "Cache-Control" => "private, no-store")
  end

  def reader_shell_boot(view)
    boot = { version: 1, runtime: "rails", view: view, mount: web_preview_path, api: web_preview_api_session_path.delete_suffix("/session"),
      reader_formats: Consumer::ReaderFormats::SUPPORTED, offline: web_preview_offline_boot, classic_downloads: consumer_downloads_path }
    return boot unless view == "reader"

    boot.merge(reader_engine: helpers.asset_path("consumer_reader_engine.js"),
      page_engine: { engine: helpers.asset_path("consumer_pdf_engine.js"), **helpers.consumer_pdf_resources })
  end

  def web_preview_offline_boot
    { worker: web_preview_offline_worker_path, scope: web_preview_offline_scope, downloads: web_preview_downloads_path,
      continuity_cookie: offline_continuity_cookie }
  end

  def web_preview_offline_scope
    "#{web_preview_path}/read/"
  end

  def web_preview_offline_cache
    web_preview_path == "/preview" ? "#{OFFLINE_CACHE}|" : "#{OFFLINE_CACHE}@#{web_preview_path}|"
  end
end
