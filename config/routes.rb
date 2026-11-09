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
  end

  scope "kobo/:kobo_token", controller: :kobo, defaults: { format: :json } do
    get "v1/initialization", action: :initialization
    post "v1/auth/device", action: :auth
    post "v1/auth/refresh", action: :auth
    get "v1/library/sync", action: :sync
    get "v1/library/tags", action: :tags
    get "v1/library/:entitlement_id/metadata", action: :metadata
    match "v1/library/:entitlement_id/state", action: :state, via: [ :get, :put ]
    get "download/:entitlement_id/:revision_id", action: :download
    get ":entitlement_id/:width/:height/:greyscale/image.jpg", action: :cover
    get ":entitlement_id/:width/:height/:quality/:greyscale/image.jpg", action: :cover
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
  put "read/:id/progress", to: "consumer/library#progress", as: :consumer_progress
  put "read/:id/reading_status", to: "consumer/library#reading_status", as: :consumer_reading_status

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
