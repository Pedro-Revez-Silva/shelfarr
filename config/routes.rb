Rails.application.routes.draw do
  resource :session do
    get :verify_otp, on: :member
    post :submit_otp, on: :member
  end
  get "sign_up", to: "registrations#new", as: :sign_up
  post "sign_up", to: "registrations#create"

  get "auth/oidc/callback", to: "auth/omniauth_callbacks#oidc"
  get "auth/failure", to: "auth/omniauth_callbacks#failure"

  root "dashboard#index"

  get "search", to: "search#index"
  get "search/details", to: "search#details"
  get "search/modal/close", to: "search#close_modal", as: :search_modal_close
  get "search/results", to: "search#results"
  get "search/results/stream", to: "search#stream_results"
  get "search/results/snapshot", to: "search#snapshot_results"

  get "discover", to: "discover#index", as: :discover
  get "discover/lists", to: "discover#lists", as: :discover_lists
  get "discover/lists/:id", to: "discover#list", as: :discover_list
  get "discover/authors", to: "discover#authors", as: :discover_authors
  get "discover/authors/:id", to: "discover#author", as: :discover_author

  namespace :hardcover do
    resource :connection, only: [ :create, :destroy ] do
      post :authorize
      get :callback
      post :device
      get :device, action: :show_device
      post :device_poll
    end
    resources :subscriptions, only: [ :index, :create, :show, :update, :destroy ] do
      member do
        post :request_items
        post :refresh
        post :pause
        post :resume
        match "items/:item_id", action: :update_item, as: :item, via: [ :post, :patch ]
      end
    end
  end

  resources :library, only: [ :index, :show, :destroy ] do
    member do
      get :download
      post :retry_post_processing
    end
  end

  resource :profile, only: [ :show, :edit, :update ] do
    get :password, on: :member
    patch :update_password, on: :member
    post :link_oidc, on: :member
    delete :unlink_oidc, on: :member
    post :api_tokens, to: "profiles#create_api_token"
    delete "api_tokens/:id", to: "profiles#revoke_api_token", as: :api_token
    get :two_factor, on: :member
    post :enable_two_factor, on: :member
    delete :disable_two_factor, on: :member
    post :regenerate_backup_codes, on: :member
  end

  resources :kobo_accounts, only: [ :index, :create, :show, :destroy ] do
    post :poll, on: :member
    post :sync, on: :member
    resources :shares, only: [ :create, :destroy ], controller: "kobo_account_shares"
  end

  # Household sharing: catalogues other users explicitly shared with you, and
  # private DRM-free copies sent to your own Kobo reader.
  resources :kobo_shared_libraries, only: [ :index, :show ], path: "kobo_shared"
  resources :kobo_account_books, only: [ :show ], path: "kobo_books" do
    member do
      post :prepare
      post :deliver
      post :status
      get :cover
    end
  end

  resources :kobo_devices, only: [ :index, :create, :show, :update, :destroy ] do
    post :rotate, on: :member
    post :send_book, on: :member
    post :use_kobo_place, on: :member
    post :send_shelfarr_place, on: :member
  end

  scope "kobo/:kobo_token", controller: :kobo, defaults: { format: :json } do
    get "v1/initialization", action: :initialization
    post "v1/auth/device", action: :auth
    post "v1/auth/refresh", action: :auth
    get "v1/library/sync", action: :sync
    get "v1/library/tags", action: :tags
    post "v1/library/tags", action: :create_tag
    match "v1/library/tags/:tag_id", action: :update_tag, via: [ :put, :delete ]
    post "v1/library/tags/:tag_id/items", action: :add_tag_items
    post "v1/library/tags/:tag_id/Items", action: :add_tag_items
    post "v1/library/tags/:tag_id/items/delete", action: :remove_tag_items
    get "v1/library/:entitlement_id/metadata", action: :metadata
    match "v1/library/:entitlement_id/state", action: :state, via: [ :get, :put ]
    get "download/:entitlement_id/:revision_id", action: :download
    get ":entitlement_id/:width/:height/:greyscale/image.jpg", action: :cover
    get ":entitlement_id/:width/:height/:quality/:greyscale/image.jpg", action: :cover
    %w[v1/user/profile v1/user/wishlist v1/user/loyalty/benefits v1/deals v1/affiliate].each do |path|
      get path, action: :optional_store_resource
    end
    post "v1/analytics/gettests", action: :optional_store_resource
    post "v1/analytics/event", action: :optional_store_resource
    # Unknown firmware endpoints must not produce a RoutingError containing
    # the unfiltered capability URL in its exception message.
    match "*unmatched", action: :unsupported, via: :all
    match "", action: :unsupported, via: :all
  end

  resources :notifications, only: [ :index ] do
    member do
      post :mark_read
    end
    collection do
      post :mark_all_read
      delete :clear_all
    end
  end

  resources :requests, only: [ :index, :show, :new, :create, :destroy ] do
    member do
      get :download
      post :manual_magnet
      post :manual_nzb
      post :retry
    end
  end

  resources :uploads, only: [ :index, :new, :create, :show ]

  namespace :api, defaults: { format: :json } do
    namespace :consumer do
      namespace :v1 do
        post "auth/device", to: "auth#device"
        post "auth/token", to: "auth#token"
        post "auth/revoke", to: "accounts#revoke"
        get "me", to: "accounts#show"
        get "server", to: "server#show", as: :server, format: true, constraints: { format: "json" }
        get "continue", to: "library#continue"
        get "discover", to: "discover#index"
        resources :requests, only: [ :index, :show, :create, :destroy ]
        get "library/:id/assets/:asset_id", to: "library#asset", as: :asset
        get "library/:id/assets/:asset_id/reading_order", to: "library#reading_order", as: :asset_reading_order
        get "library/:id/assets/:asset_id/read_along", to: "library#read_along", as: :asset_read_along
        get "library/:id/assets/:asset_id/read_along/resources/*path", to: "library#read_along_resource", as: :asset_read_along_resource, format: false
        get "library/:id/assets/:asset_id/read_along/audio/:audio_asset_id", to: "library#read_along_audio", as: :asset_read_along_audio
        post "library/:id/assets/:asset_id/transfer_grant", to: "library#transfer_grant", as: :asset_transfer_grant
        get "library/:id/assets/:asset_id/transfer", to: "transfers#show", as: :asset_transfer
        resources :library, only: [ :index, :show ] do
          get :progress, to: "progress#show", on: :member
          put :progress, to: "progress#update", on: :member
          put :reading_status, to: "reading_status#update", on: :member
        end
      end
    end
    namespace :v1 do
      get "search", to: "search#index"
      resources :requests, only: [ :index, :create, :show, :destroy ] do
        member do
          get :search_results
          post :grab
          post :blocklist_and_next
          post :retry
        end
      end
      resources :users, only: [ :create ]
    end
  end

  # Public Android downloads: a landing page, one feed per channel and the
  # cached APK bytes. No account is needed and nothing is fetched upstream here.
  get "apps/android", to: "android_apps#show", as: :android_app, format: false
  get "apps/android/:channel", to: "android_app_files#feed", as: :android_app_feed,
    format: true, constraints: { channel: /release|development/, format: "json" }
  get "apps/android/:channel/:file", to: "android_app_files#apk", as: :android_app_apk,
    format: false, constraints: { channel: /release|development/, file: /[1-9]\d{0,9}-[0-9a-f]{64}\.apk/ }

  get "manifest.webmanifest", to: "web_app_manifests#show", as: :web_app_manifest, format: false
  get "consumer/connect", to: "consumer/connections#show", as: :consumer_connect
  post "consumer/connect", to: "consumer/connections#create"
  get "read-offline-worker.js", to: "consumer/offline#worker", as: :consumer_offline_worker, format: false
  get "read", to: "consumer/library#index", as: :consumer_library
  get "read/offline", to: "consumer/offline#shell", as: :consumer_offline_shell, format: false
  get "read/offline/account", to: "consumer/offline#account", as: :consumer_offline_account, defaults: { format: :json }
  get "read/offline/publications", to: "consumer/offline#publications", as: :consumer_offline_publications, defaults: { format: :json }
  get "read/downloads", to: "consumer/offline#downloads", as: :consumer_downloads, format: false
  get "read/:id", to: "consumer/library#show", as: :consumer_publication
  get "read/:id/assets/:asset_id", to: "consumer/library#asset", as: :consumer_asset
  get "read/:id/assets/:asset_id/reading_order", to: "consumer/library#reading_order", as: :consumer_asset_reading_order
  get "read/:id/assets/:asset_id/read_along", to: "consumer/library#read_along", as: :consumer_read_along
  get "read/:id/assets/:asset_id/read_along/resources/*path", to: "consumer/library#read_along_resource", as: :consumer_read_along_resource, format: false
  get "read/:id/assets/:asset_id/read_along/audio/:audio_asset_id", to: "consumer/library#read_along_audio", as: :consumer_read_along_audio
  put "read/:id/progress", to: "consumer/library#progress", as: :consumer_progress
  put "read/:id/reading_status", to: "consumer/library#reading_status", as: :consumer_reading_status

  get "preview", to: "web_preview/shell#index", as: :web_preview
  get "preview/library", to: "web_preview/shell#show", as: :web_preview_library
  get "preview/library/:id", to: "web_preview/shell#show", as: :web_preview_publication, constraints: { id: /[1-9]\d{0,18}/ }
  get "preview/library/:id/read", to: "web_preview/shell#moved_reader", constraints: { id: /[1-9]\d{0,18}/ }
  get "preview/library/downloads", to: "web_preview/shell#moved_downloads"
  get "preview/read/downloads", to: "web_preview/shell#downloads", as: :web_preview_downloads
  get "preview/read/offline-worker.js", to: "web_preview/offline_worker#show", as: :web_preview_offline_worker, format: false
  get "preview/read/:id", to: "web_preview/shell#reader", as: :web_preview_reader, constraints: { id: /[1-9]\d{0,18}/ }
  get "preview/discover", to: "web_preview/shell#show", as: :web_preview_discover
  get "preview/books/:source/:source_id", to: "web_preview/shell#show", as: :web_preview_book,
    constraints: { source: /hardcover|google_books|openlibrary|comic_vine/, source_id: /[A-Za-z0-9_-]{1,64}/ }
  get "preview/requests", to: "web_preview/shell#show", as: :web_preview_requests
  get "preview/requests/:id", to: "web_preview/shell#show", as: :web_preview_request, constraints: { id: /[1-9]\d{0,18}/ }
  get "preview/account", to: "web_preview/shell#show", as: :web_preview_account
  get "preview/account/:section", to: "web_preview/shell#show", as: :web_preview_account_section, constraints: { section: /security|devices|connections|about/ }
  get "preview/find", to: "web_preview/shell#show", as: :web_preview_find
  scope "preview/api/v1", module: :web_preview, as: :web_preview_api, defaults: { format: :json } do
    get "session", to: "sessions#show"
    get "continue", to: "library#continue"
    get "library", to: "library#index"
    get "library/:id", to: "library#show"
    put "library/:id/reading_status", to: "library#reading_status"
    get "auth/bootstrap", to: "bootstrap#show"
    get "library/:id/reader", to: "reader#show", as: :reader
    get "library/:id/progress", to: "reader#progress", as: :progress
    put "library/:id/progress", to: "reader#save_progress"
    get "library/:id/assets/:asset_id/reading_order", to: "reader#reading_order", as: :reading_order
    get "accounts/:account/library/:id/assets/:asset_id", to: "media#show", as: :media
    get "discover", to: "discover#index"
    constraints source: /hardcover|google_books|openlibrary|comic_vine/, source_id: /[A-Za-z0-9_-]{1,64}/ do
      get "books/:source/:source_id", to: "books#show", as: :book
      post "books/:source/:source_id/requests", to: "books#create_request", as: :book_requests
    end
    post "requests/:id/selection", to: "requests#selection", as: :request_selection
    post "requests/:id/search", to: "requests#search", as: :request_search
    post "requests/:id/cancel", to: "requests#cancel", as: :request_cancel
    get "requests", to: "requests#index", as: :requests
    get "requests/:id", to: "requests#show", as: :request
    post "requests/:id/retry", to: "requests#retry", as: :request_retry
    post "requests/:id/remove", to: "requests#remove", as: :request_remove
    post "requests/:id/manual", to: "requests#manual", as: :request_manual
    get "account", to: "accounts#show", as: :account
    put "account/profile", to: "accounts#profile", as: :account_profile
    post "account/password", to: "accounts#password", as: :account_password
    post "account/two_factor/setup", to: "account_security#setup_two_factor", as: :account_two_factor_setup
    post "account/two_factor/enable", to: "account_security#enable_two_factor", as: :account_two_factor_enable
    post "account/two_factor/disable", to: "account_security#disable_two_factor", as: :account_two_factor_disable
    post "account/two_factor/backup_codes", to: "account_security#backup_codes", as: :account_backup_codes
    post "account/api_tokens", to: "account_security#create_api_token", as: :account_api_tokens
    post "account/api_tokens/:id/revoke", to: "account_security#revoke_api_token", as: :account_api_token_revoke
    post "account/oidc/unlink", to: "account_security#unlink_oidc", as: :account_oidc_unlink
  end

  get "preview/admin", to: "web_preview/shell#show", as: :web_preview_admin
  get "preview/admin/settings", to: "web_preview/shell#show", as: :web_preview_admin_settings
  get "preview/server", to: "web_preview/shell#show", as: :web_preview_server
  get "preview/server/setup", to: "web_preview/shell#show", as: :web_preview_server_setup
  get "preview/admin/setup_wizard", to: "web_preview/shell#show", as: :web_preview_admin_setup_wizard
  get "preview/server/:category", to: "web_preview/shell#show", as: :web_preview_server_category,
    constraints: { category: /policy|sources|downloads|library|notifications|people|system/ }
  scope "preview/api/v1/admin", module: "web_preview/admin", as: :web_preview_api_admin, defaults: { format: :json } do
    get "overview", to: "overview#show"
    get "setup", to: "setup#show"
    put "setup/steps/:step", to: "setup#update", as: :setup_step, constraints: { step: /[a-z_]{1,40}/ }
    post "setup/skip", to: "setup#skip", as: :setup_skip
    post "setup/restart", to: "setup#restart", as: :setup_restart
    post "overview/health_check", to: "overview#health_check", as: :health_check
    post "overview/update_check", to: "overview#update_check", as: :update_check
    get "settings", to: "settings#show"
    put "settings/groups/:group", to: "settings#update", as: :settings_group, constraints: { group: /[a-z_]{1,40}/ }
    post "settings/probes/:probe", to: "settings#probe", as: :settings_probe, constraints: { probe: /[a-z_]{1,40}/ }
    get "settings/library", to: "library#show", as: :settings_library
    post "settings/library/sync", to: "library#sync", as: :settings_library_sync
    get "settings/telegram_chats", to: "telegram_chats#index", as: :telegram_chats
    post "settings/telegram_chats", to: "telegram_chats#create"
    post "settings/telegram_chats/:id/pause", to: "telegram_chats#pause", as: :telegram_chat_pause
    post "settings/telegram_chats/:id/resume", to: "telegram_chats#resume", as: :telegram_chat_resume
    delete "settings/telegram_chats/:id", to: "telegram_chats#destroy", as: :telegram_chat
    get "downloads", to: "downloads#show"
    post "downloads/clients", to: "downloads#create_client", as: :download_clients
    put "downloads/clients/:id", to: "downloads#update_client", as: :download_client
    delete "downloads/clients/:id", to: "downloads#destroy_client"
    post "downloads/clients/:id/test", to: "downloads#test_client", as: :download_client_test
    post "downloads/clients/:id/move", to: "downloads#move_client", as: :download_client_move
    post "downloads/rules", to: "downloads#create_rule", as: :download_rules
    put "downloads/rules/:id", to: "downloads#update_rule", as: :download_rule
    delete "downloads/rules/:id", to: "downloads#destroy_rule"
  end

  namespace :integrations, defaults: { format: :json } do
    post "telegram/webhook", to: "telegram_webhooks#create"
  end

  namespace :admin do
    root "dashboard#index"
    post "check_updates", to: "dashboard#check_updates"
    post "run_health_check", to: "dashboard#run_health_check"
    resources :users
    resources :uploads, only: [ :index, :new, :create, :show, :destroy ] do
      member do
        post :retry
        post :match_and_retry
      end
    end
    resource :setup_wizard, only: [ :show, :update ], controller: "setup_wizard" do
      post :skip
      post :restart
    end
    resources :download_clients do
      member do
        post :test
        post :move_up
        post :move_down
      end
    end
    resources :acquisition_providers do
      member do
        post :test
      end
    end
    resources :owned_library_connections, only: [ :index, :create, :update ] do
      member do
        post :test
        post :auth_start
        post :auth_complete
        post :sync
        post :backup_existing
        post :dismiss_existing_backup
        patch :automation, action: :update_automation
        post "items/:item_id/backup", action: :backup, as: :backup_item
      end
    end
    resources :download_routing_rules, except: [ :show ]
    resources :settings, only: [ :index, :update ] do
      collection do
        patch :bulk_update
        post :test_indexer
        post :test_prowlarr
        post :sync_audiobookshelf_library
        post :test_audiobookshelf
        post :test_flaresolverr
        post :test_zlibrary
        post :test_gutenberg
        post :test_librivox
        post :test_ebooks_com
        post :test_hardcover
        post :test_google_books
        post :test_open_library
        post :test_comic_vine
        post :test_oidc
        post :test_webhook
        post :test_discord
        post :test_telegram
        post :setup_telegram_webhook
        post :approve_telegram_chat
        post "telegram_chats/:id/pause", to: "settings#pause_telegram_chat", as: :pause_telegram_chat
        post "telegram_chats/:id/resume", to: "settings#resume_telegram_chat", as: :resume_telegram_chat
        delete "telegram_chats/:id", to: "settings#delete_telegram_chat", as: :delete_telegram_chat
      end
    end
    resource :bulk_operations, only: [] do
      post :retry_selected
      post :cancel_selected
      post :retry_all
    end
    resources :activity_logs, only: [ :index ]
    resources :requests, only: [] do
      resources :search_results, only: [ :index ] do
        member do
          post :select
        end
        collection do
          post :refresh
        end
      end
    end
  end

  get "up" => "rails/health#show", as: :rails_health_check
end
