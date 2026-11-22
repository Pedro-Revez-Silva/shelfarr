# frozen_string_literal: true

module WarmEntry
  extend ActiveSupport::Concern

  STYLESHEET = "web/preview.css"

  included do
    layout :entry_layout
    before_action :choose_entry_variant
  end

  def self.stylesheet_built?
    Rails.application.assets.resolver.resolve(STYLESHEET).present?
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
    warm_entry? ? "entry" : "application"
  end
end
