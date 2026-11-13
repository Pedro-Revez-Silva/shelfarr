# frozen_string_literal: true

module Kobo
  # Classifies the download variants Kobo lists for a catalogue title.
  #
  # Only a full EPUB or EPUB3 marked SignedNoDrm, served from Kobo's fixed
  # HTTPS download host, has been verified to deliver a DRM-free file. Every
  # other variant (Adobe or Kobo DRM, an unlabelled or "None" DRM type, KEPUB,
  # fixed-layout, PDF, samples) is reported as protected or unsupported rather
  # than guessed. Shelfarr never removes DRM or transfers content keys.
  module DownloadRights
    FORMATS = %w[EPUB3 EPUB].freeze
    VERIFIED_DRM = "SignedNoDrm"
    DOWNLOAD_HOST = "storedownloads.kobo.com"
    PROTECTED_FORMATS = %w[EPUB EPUB3 EPUB3FL KEPUB PDF].freeze
    MAX_URL_BYTES = 8.kilobytes
    Choice = Data.define(:rights, :format, :size, :url)

    module_function

    def classify(download_urls)
      entries = download_urls.is_a?(Array) ? download_urls.select { |entry| entry.is_a?(Hash) } : []
      return Choice.new(rights: "none_offered", format: nil, size: nil, url: nil) if entries.empty?

      free = entries.select do |entry|
        FORMATS.include?(entry["Format"]) && entry["DrmType"] == VERIFIED_DRM && trusted_url?(entry["Url"])
      end
      chosen = FORMATS.lazy.filter_map { |format| free.find { |entry| entry["Format"] == format } }.first
      if chosen
        return Choice.new(rights: "drm_free", format: chosen["Format"], size: size(chosen["Size"]), url: chosen["Url"])
      end

      protected = entries.any? do |entry|
        PROTECTED_FORMATS.include?(entry["Format"]) && entry["DrmType"].is_a?(String) &&
          !%w[None SignedNoDrm].include?(entry["DrmType"])
      end
      Choice.new(rights: protected ? "protected" : "unsupported", format: nil, size: nil, url: nil)
    end

    # The signed URL must be Kobo's own HTTPS download host on the default
    # port, with no credentials or fragment. It is never stored or logged.
    def trusted_url?(value)
      return false unless value.is_a?(String) && value.bytesize <= MAX_URL_BYTES && !value.match?(/[\x00-\x20\x7f\\]/)

      uri = parse(value)
      uri.is_a?(URI::HTTPS) && uri.host == DOWNLOAD_HOST && uri.port == 443 && uri.userinfo.nil? &&
        uri.fragment.nil? && uri.path.start_with?("/")
    end

    # An unparseable address becomes an empty generic URI, which is never trusted.
    def parse(value)
      URI.parse(value)
    rescue URI::InvalidURIError
      URI::Generic.build({})
    end

    def size(value)
      number = value.is_a?(Integer) ? value : Integer(value.to_s, 10, exception: false)
      number if number&.between?(1, KoboPublication::MAX_EPUB_BYTES)
    end
  end
end
