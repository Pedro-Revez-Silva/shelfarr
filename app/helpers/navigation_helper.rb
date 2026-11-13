# frozen_string_literal: true

module NavigationHelper
  SECTIONS = {
    library: %w[consumer/library consumer/offline library],
    discover: %w[search discover hardcover/subscriptions],
    requests: %w[requests],
    uploads: %w[uploads],
    admin: %w[admin/],
    account: %w[profiles kobo_devices kobo_accounts kobo_shared_libraries kobo_account_books notifications]
  }.freeze

  def navigation_section
    SECTIONS.find do |_section, paths|
      paths.any? { |path| path.end_with?("/") ? controller_path.start_with?(path) : controller_path == path }
    end&.first
  end

  def navigation_link(label, path, section, **options)
    current = navigation_section == section
    link_to label, path, **options.except(:class),
      class: class_names(options[:class], current ? "text-white underline decoration-blue-500 decoration-2 underline-offset-8" : "text-gray-400 hover:text-white"),
      aria: { current: ("page" if current) }
  end

  def discover_entry_path
    hardcover_catalog_available? ? discover_path : search_path
  end

  def hardcover_catalog_available?
    return @hardcover_catalog_available if defined?(@hardcover_catalog_available)

    @hardcover_catalog_available = Hardcover::Credentials.catalog_available?(user: Current.user)
  end

  def release_channel
    Shelfarr::ReleaseChannel.current
  end
end
