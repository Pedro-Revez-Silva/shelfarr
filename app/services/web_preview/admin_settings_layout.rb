# frozen_string_literal: true

module WebPreview
  module AdminSettingsLayout
    HIDDEN_KEYS = %i[setup_wizard_completed].freeze

    CATEGORIES = [
      {
        id: "policy",
        title: "Request policy",
        summary: "What happens when someone asks for a book, and how Shelfarr picks a copy.",
        groups: [
          {
            id: "new_requests",
            title: "New requests",
            summary: "What people see when they ask for a book, and whether it starts straight away.",
            fields: %i[auto_approve_requests default_request_format immediate_search_enabled],
            advanced: %i[queue_batch_size rate_limit_delay max_retries retry_base_delay_hours retry_max_delay_days]
          },
          {
            id: "automatic_selection",
            title: "Automatic selection",
            summary: "When Shelfarr may choose a copy without asking an administrator.",
            fields: %i[auto_select_enabled auto_select_confidence_threshold auto_select_min_seeders]
          },
          {
            id: "languages",
            title: "Languages",
            summary: "Which languages people can ask for, and how closely a release must match.",
            fields: %i[default_language enabled_languages],
            advanced: %i[min_match_confidence]
          },
          {
            id: "formats",
            title: "Formats and sizes",
            summary: "Which file formats may be chosen automatically, in what order, and size limits. Rejected formats stay available for a manual choice.",
            fields: %i[ebook_preferred_formats audiobook_preferred_formats ebook_rejected_formats audiobook_rejected_formats],
            advanced: %i[ebook_approved_formats audiobook_approved_formats ebook_min_file_size ebook_max_file_size audiobook_min_file_size audiobook_max_file_size audiobook_prefer_single_file audiobook_prefer_higher_bitrate]
          }
        ]
      },
      {
        id: "sources",
        title: "Catalogues and sources",
        summary: "Where Shelfarr looks up books and where it finds copies.",
        groups: [
          {
            id: "hardcover",
            heading: "Catalogues",
            title: "Hardcover",
            summary: "Book details and reading lists from Hardcover.",
            toggle: :hardcover_enabled,
            fields: %i[hardcover_enabled hardcover_api_token],
            advanced: %i[hardcover_search_limit],
            probes: [ { id: "hardcover", label: "Test", uses: "saved" } ],
            health: "hardcover"
          },
          {
            id: "hardcover_accounts",
            heading: "Catalogues",
            title: "Hardcover accounts",
            summary: "Let each person connect their own Hardcover account for Want to Read and lists.",
            fields: %i[hardcover_oauth_client_id hardcover_oauth_client_secret hardcover_oauth_device_flow_enabled],
            advanced: %i[hardcover_oauth_redirect_uri hardcover_allow_personal_access hardcover_sync_interval_hours hardcover_max_requests_per_run],
            notes: %w[hardcover_app]
          },
          {
            id: "google_books",
            heading: "Catalogues",
            title: "Google Books",
            summary: "Book details from Google Books. A key is optional.",
            toggle: :google_books_enabled,
            fields: %i[google_books_enabled google_books_api_key],
            advanced: %i[google_books_search_limit],
            probes: [ { id: "google_books", label: "Test", uses: "saved" } ]
          },
          {
            id: "open_library",
            heading: "Catalogues",
            title: "Open Library",
            summary: "Free book details from openlibrary.org.",
            toggle: :open_library_enabled,
            fields: %i[open_library_enabled],
            advanced: %i[open_library_search_limit],
            probes: [ { id: "open_library", label: "Test", uses: "saved" } ]
          },
          {
            id: "comic_vine",
            heading: "Catalogues",
            title: "Comic Vine",
            summary: "Details for comics and manga. Needs an API key.",
            toggle: :comic_vine_enabled,
            fields: %i[comic_vine_enabled comic_vine_api_key],
            advanced: %i[comic_vine_search_limit],
            probes: [ { id: "comic_vine", label: "Test", uses: "saved" } ]
          },
          {
            id: "catalogue_order",
            heading: "Catalogues",
            title: "Catalogue order",
            summary: "Which catalogues are searched, and which one wins when they disagree.",
            fields: %i[metadata_source],
            advanced: %i[metadata_provider_priority]
          },
          {
            id: "indexer",
            heading: "File sources",
            title: "Indexer",
            summary: "The single indexer Shelfarr asks for torrent and usenet releases.",
            fields: %i[indexer_provider prowlarr_url prowlarr_api_key jackett_url jackett_api_key newznab_url newznab_api_key],
            advanced: %i[prowlarr_tags jackett_indexer_filter indexer_search_scope indexer_custom_audiobook_categories indexer_custom_ebook_categories indexer_custom_comicbook_categories],
            probes: [ { id: "indexer", label: "Test", uses: "draft" } ],
            health: "indexer"
          },
          {
            id: "anna_archive",
            heading: "File sources",
            title: "Anna's Archive",
            summary: "An extra search and direct download source.",
            toggle: :anna_archive_enabled,
            fields: %i[anna_archive_enabled anna_archive_api_key anna_archive_url],
            advanced: %i[flaresolverr_url],
            probes: [ { id: "flaresolverr", label: "Test FlareSolverr", uses: "saved" } ]
          },
          {
            id: "zlibrary",
            heading: "File sources",
            title: "Z-Library",
            summary: "An unofficial ebook search and direct download source that may break if the service changes.",
            toggle: :zlibrary_enabled,
            fields: %i[zlibrary_enabled zlibrary_email zlibrary_password],
            advanced: %i[zlibrary_url zlibrary_remix_userid zlibrary_remix_userkey],
            probes: [ { id: "zlibrary", label: "Test", uses: "saved" } ]
          },
          {
            id: "gutenberg",
            heading: "File sources",
            title: "Project Gutenberg",
            summary: "Free public-domain ebooks.",
            toggle: :gutenberg_enabled,
            fields: %i[gutenberg_enabled],
            advanced: %i[gutenberg_url gutenberg_search_limit],
            probes: [ { id: "gutenberg", label: "Test", uses: "saved" } ]
          },
          {
            id: "librivox",
            heading: "File sources",
            title: "LibriVox",
            summary: "Free public-domain audiobooks.",
            toggle: :librivox_enabled,
            fields: %i[librivox_enabled],
            advanced: %i[librivox_url librivox_search_limit],
            probes: [ { id: "librivox", label: "Test", uses: "saved" } ]
          },
          {
            id: "ebooks_com",
            heading: "File sources",
            title: "eBooks.com store (beta)",
            summary: "Show DRM-free offers people can buy. Checkout stays on eBooks.com.",
            toggle: :ebooks_com_enabled,
            fields: %i[ebooks_com_enabled ebooks_com_country_code],
            advanced: %i[ebooks_com_search_limit],
            probes: [ { id: "ebooks_com", label: "Test", uses: "saved" } ]
          }
        ]
      },
      {
        id: "downloads",
        title: "Downloads",
        summary: "Which releases Shelfarr prefers and where download clients put their files.",
        groups: [
          {
            id: "release_types",
            title: "Release types",
            summary: "When a book is found as several kinds of release, the higher one wins.",
            fields: %i[preferred_download_types]
          },
          {
            id: "path_mapping",
            title: "Path mapping",
            summary: "Where Shelfarr finds the files a download client reports.",
            fields: %i[download_local_path download_remote_path],
            health: "download_paths"
          },
          {
            id: "download_handling",
            title: "Download handling",
            summary: "How often Shelfarr checks downloads and what it does when they finish.",
            fields: %i[remove_completed_usenet_downloads],
            advanced: %i[download_check_interval download_enqueue_timeout_minutes precreate_download_archives]
          }
        ]
      },
      {
        id: "library",
        title: "Library and files",
        summary: "Where finished books go, how they are named, and the library app Shelfarr delivers to.",
        groups: [
          {
            id: "folders",
            title: "Folders",
            summary: "Where Shelfarr puts finished books.",
            fields: %i[ebook_output_path audiobook_output_path comicbook_output_path],
            health: "output_paths"
          },
          {
            id: "naming",
            title: "Folder and file names",
            summary: "How each book's folder and file are named. Leave a folder pattern blank to put files straight into the output folder.",
            fields: %i[ebook_path_template ebook_filename_template audiobook_path_template audiobook_filename_template],
            advanced: %i[comicbook_path_template comicbook_filename_template],
            notes: %w[path_variables]
          },
          {
            id: "importing",
            title: "Importing",
            summary: "How a finished download becomes a library file.",
            fields: %i[completed_download_import_mode split_audiobook_bundle_imports],
            advanced: %i[library_import_file_mode library_import_folder_mode post_processing_source_path_retries allow_nonatomic_nfs_directory_publication]
          },
          {
            id: "library_platform",
            heading: "Library platform",
            title: "Connection",
            summary: "The library app Shelfarr delivers to and checks for books you already have.",
            fields: %i[library_platform audiobookshelf_url audiobookshelf_api_key bookorbit_url bookorbit_username bookorbit_password grimmory_url grimmory_username grimmory_password],
            probes: [ { id: "audiobookshelf", label: "Test", uses: "draft" } ],
            health: "audiobookshelf"
          },
          {
            id: "library_delivery",
            heading: "Library platform",
            title: "Libraries",
            summary: "Which library receives each kind of book, and which others are checked for duplicates.",
            fields: %i[audiobookshelf_ebook_library_id audiobookshelf_audiobook_library_id audiobookshelf_comicbook_library_id],
            advanced: %i[audiobookshelf_ebook_scan_library_ids audiobookshelf_audiobook_scan_library_ids audiobookshelf_comicbook_scan_library_ids audiobookshelf_library_sync_interval],
            extras: %w[library_inventory]
          }
        ]
      },
      {
        id: "notifications",
        title: "Notifications",
        summary: "Tell other apps and chats when requests change.",
        groups: [
          {
            id: "discord",
            title: "Discord",
            summary: "Post request updates to a Discord channel.",
            toggle: :discord_enabled,
            fields: %i[discord_enabled discord_webhook_url discord_events],
            probes: [ { id: "discord", label: "Send a test message", uses: "saved" } ]
          },
          {
            id: "telegram",
            title: "Telegram",
            summary: "Let approved Telegram groups request books and hear back.",
            toggle: :telegram_enabled,
            fields: %i[telegram_enabled telegram_bot_token telegram_bot_username telegram_webhook_secret],
            advanced: %i[telegram_update_mode telegram_request_username telegram_notification_events telegram_allowed_chat_ids],
            probes: [ { id: "telegram", label: "Test the bot", uses: "saved" }, { id: "telegram_webhook", label: "Switch to webhook delivery", uses: "saved", changes: true } ],
            extras: %w[telegram_chats]
          },
          {
            id: "webhook",
            title: "Webhook",
            summary: "Send a JSON message to another service, such as ntfy or Home Assistant.",
            toggle: :webhook_enabled,
            fields: %i[webhook_enabled webhook_url webhook_events],
            advanced: %i[webhook_token webhook_topic],
            probes: [ { id: "webhook", label: "Send a test webhook", uses: "saved" } ]
          }
        ]
      },
      {
        id: "people",
        title: "People and access",
        summary: "Who can sign in, how, and what members may do.",
        groups: [
          {
            id: "member_permissions",
            title: "What members can do",
            summary: "Members are everyone who is not an administrator.",
            fields: %i[allow_user_uploads],
            extras: %w[roles]
          },
          {
            id: "sign_in",
            title: "Sign-in rules",
            summary: "Session length and protection against guessed passwords.",
            fields: %i[session_max_age_days login_lockout_threshold login_lockout_duration_minutes],
            advanced: %i[auth_disabled api_token]
          },
          {
            id: "single_sign_on",
            title: "Single sign-on",
            summary: "Sign in with your identity provider using OpenID Connect.",
            toggle: :oidc_enabled,
            fields: %i[oidc_enabled oidc_provider_name oidc_issuer oidc_client_id oidc_client_secret],
            advanced: %i[oidc_scopes oidc_auto_redirect oidc_auto_create_users oidc_default_role oidc_link_existing_users],
            probes: [ { id: "oidc", label: "Test", uses: "saved" } ]
          }
        ]
      },
      {
        id: "system",
        title: "System",
        summary: "Health checks and where Shelfarr looks for new releases.",
        groups: [
          {
            id: "health_checks",
            title: "Health checks",
            summary: "How often Shelfarr checks its connections. Run a check now from the overview.",
            fields: %i[health_check_interval]
          },
          {
            id: "updates",
            title: "Update source",
            summary: "Where Shelfarr looks for new releases.",
            fields: %i[github_repo]
          }
        ]
      }
    ].freeze

    LABELS = {
      indexer_provider: "Indexer",
      prowlarr_url: "Prowlarr address",
      prowlarr_api_key: "Prowlarr API key",
      prowlarr_tags: "Prowlarr tags",
      jackett_url: "Jackett address",
      jackett_api_key: "Jackett API key",
      newznab_url: "Newznab address",
      newznab_api_key: "Newznab API key",
      indexer_search_scope: "Search scope",
      indexer_custom_audiobook_categories: "Audiobook categories",
      indexer_custom_ebook_categories: "Ebook categories",
      indexer_custom_comicbook_categories: "Comics & Manga categories",
      preferred_download_types: "Preferred release types",
      auto_select_enabled: "Choose a copy automatically",
      auto_select_confidence_threshold: "Minimum match for automatic choice",
      auto_select_min_seeders: "Minimum seeders for automatic choice",
      min_match_confidence: "Minimum match for broad searches",
      ebook_preferred_formats: "Preferred ebook formats",
      audiobook_preferred_formats: "Preferred audiobook formats",
      ebook_rejected_formats: "Rejected ebook formats",
      audiobook_rejected_formats: "Rejected audiobook formats",
      ebook_approved_formats: "Allowed ebook formats",
      audiobook_approved_formats: "Allowed audiobook formats",
      audiobook_prefer_single_file: "Prefer single-file audiobooks",
      audiobook_prefer_higher_bitrate: "Prefer higher bitrate audiobooks",
      default_language: "Default language",
      enabled_languages: "Languages people can choose",
      anna_archive_enabled: "Use Anna's Archive",
      anna_archive_url: "Anna's Archive addresses",
      anna_archive_api_key: "Member API key",
      flaresolverr_url: "FlareSolverr address",
      zlibrary_enabled: "Use Z-Library",
      zlibrary_url: "Z-Library addresses",
      zlibrary_email: "Account email",
      zlibrary_password: "Account password",
      gutenberg_enabled: "Use Project Gutenberg",
      gutenberg_url: "Catalog address",
      gutenberg_search_limit: "Results per search",
      librivox_enabled: "Use LibriVox",
      librivox_url: "LibriVox address",
      librivox_search_limit: "Results per search",
      ebook_output_path: "Ebook folder",
      audiobook_output_path: "Audiobook folder",
      comicbook_output_path: "Comics & Manga folder",
      download_local_path: "Downloads folder inside Shelfarr",
      download_remote_path: "Downloads folder in the download client",
      ebook_path_template: "Ebook folder pattern",
      ebook_filename_template: "Ebook file name pattern",
      audiobook_path_template: "Audiobook folder pattern",
      audiobook_filename_template: "Audiobook file name pattern",
      comicbook_path_template: "Comics & Manga folder pattern",
      comicbook_filename_template: "Comics & Manga file name pattern",
      completed_download_import_mode: "Import method",
      remove_completed_usenet_downloads: "Remove finished usenet downloads",
      split_audiobook_bundle_imports: "Split audiobook bundles",
      download_check_interval: "Download check interval (seconds)",
      download_enqueue_timeout_minutes: "Dispatch timeout (minutes)",
      post_processing_source_path_retries: "Retries while waiting for files",
      hardcover_enabled: "Use Hardcover",
      hardcover_api_token: "API token",
      hardcover_search_limit: "Results per search",
      open_library_enabled: "Use Open Library",
      open_library_search_limit: "Results per search",
      google_books_enabled: "Use Google Books",
      google_books_api_key: "API key",
      google_books_search_limit: "Results per search",
      comic_vine_enabled: "Use Comic Vine",
      comic_vine_api_key: "API key",
      comic_vine_search_limit: "Results per search",
      metadata_source: "Sources to search",
      metadata_provider_priority: "Source priority",
      default_request_format: "Format chosen on the request form",
      auto_approve_requests: "Start everyone's requests automatically",
      immediate_search_enabled: "Search as soon as a request is made",
      max_retries: "Attempts before asking for attention",
      retry_base_delay_hours: "First wait before retrying (hours)",
      retry_max_delay_days: "Longest wait between retries (days)",
      queue_batch_size: "Requests per queue run",
      rate_limit_delay: "Pause between searches (seconds)",
      discord_enabled: "Send to Discord",
      discord_webhook_url: "Discord webhook address",
      discord_events: "Send these updates",
      webhook_enabled: "Send webhooks",
      webhook_url: "Webhook address",
      webhook_events: "Send these updates",
      webhook_token: "Bearer token",
      webhook_topic: "Topic",
      telegram_enabled: "Use the Telegram bot",
      telegram_bot_token: "Bot token",
      telegram_bot_username: "Bot username",
      telegram_webhook_secret: "Webhook secret",
      telegram_update_mode: "How Telegram reaches Shelfarr",
      telegram_request_username: "Owner of group requests",
      telegram_notification_events: "Updates sent back to groups",
      telegram_allowed_chat_ids: "Allowed group IDs",
      session_max_age_days: "Stay signed in for (days)",
      login_lockout_threshold: "Failed sign-ins before a pause",
      login_lockout_duration_minutes: "Pause length (minutes)",
      auth_disabled: "Turn off passwords",
      oidc_enabled: "Use single sign-on",
      oidc_provider_name: "Button name",
      oidc_issuer: "Issuer address",
      oidc_client_id: "Client ID",
      oidc_client_secret: "Client secret",
      oidc_scopes: "Scopes",
      oidc_auto_redirect: "Go straight to single sign-on",
      oidc_auto_create_users: "Create accounts on first sign-in",
      oidc_default_role: "Role for new accounts",
      oidc_link_existing_users: "Link matching existing accounts",
      allow_user_uploads: "Let people upload book files",
      api_token: "API token",
      health_check_interval: "Health check interval (seconds)",
      github_repo: "Release repository"
    }.freeze

    def self.groups
      CATEGORIES.flat_map { |category| category[:groups].map { |group| group.merge(category: category[:id]) } }
    end

    def self.group(id)
      groups.find { |group| group[:id] == id.to_s }
    end

    def self.keys_for(group)
      group[:fields] + group.fetch(:advanced, [])
    end
  end
end
