# frozen_string_literal: true

module WarmEntry
  extend ActiveSupport::Concern

  STYLESHEET = "web/preview.css"
  SCRIPT = "web/preview.js"

  included do
    layout :entry_layout
    before_action :choose_entry_variant
  end

  def self.stylesheet_built?
    asset_built?(STYLESHEET)
  end

  def self.preview_built?
    stylesheet_built? && asset_built?(SCRIPT)
  end

  def self.asset_built?(path)
    resolver = Rails.application.assets.resolver
    url = resolver.resolve(path)
    return false if url.nil?
    return true unless resolver.is_a?(Propshaft::Resolver::Static)

    resolver.manifest_path.dirname.join(url.delete_prefix(resolver.prefix).delete_prefix("/")).file?
  end

  private

  def warm_entry?
    return @warm_entry if defined?(@warm_entry)

    @warm_entry = WebPreview::Access.current.configured? && warm_entry_page? && WarmEntry.stylesheet_built?
  end

  def warm_entry_page?
    true
  end

  def choose_entry_variant
    request.variant = :warm if warm_entry?
  end

  def entry_layout
    "entry" if warm_entry?
  end
end
