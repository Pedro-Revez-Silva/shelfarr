# frozen_string_literal: true

class WebAppManifestsController < ApplicationController
  PAPER = "#FBF7F0"

  allow_unauthenticated_access

  def show
    headers["Cache-Control"] = "no-cache"
    render json: manifest, content_type: "application/manifest+json"
  end

  private

  def manifest
    base = request.script_name.to_s
    {
      id: "#{base}/",
      name: "Shelfarr",
      short_name: "Shelfarr",
      description: "Read and listen to your Shelfarr library.",
      lang: "en",
      start_url: consumer_library_path,
      scope: "#{base}/",
      display: "standalone",
      background_color: PAPER,
      theme_color: PAPER,
      icons: [
        icon("web_app/shelfarr-192.png", 192, "any"),
        icon("web_app/shelfarr-512.png", 512, "any"),
        icon("web_app/shelfarr-maskable-512.png", 512, "maskable")
      ]
    }
  end

  def icon(path, size, purpose)
    { src: helpers.asset_path(path), sizes: "#{size}x#{size}", type: "image/png", purpose: purpose }
  end
end
