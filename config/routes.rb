Rails.application.routes.draw do
  # Authentication
  resource :session do
    get :verify_otp, on: :member
    post :submit_otp, on: :member
  end
  get "sign_up", to: "registrations#new", as: :sign_up
  post "sign_up", to: "registrations#create"

  # OIDC/SSO Authentication (OmniAuth callbacks)
  get "auth/oidc/callback", to: "auth/omniauth_callbacks#oidc"
  get "auth/failure", to: "auth/omniauth_callbacks#failure"

  # Main application
  root "dashboard#index"

  # Search
  get "search", to: "search#index"
  get "search/results", to: "search#results"

  # Library
  resources :library, only: [ :index, :show, :destroy ] do
    member do
      post :retry_post_processing
    end
  end

  # Profile
  resource :profile, only: [ :show, :edit, :update ] do
    get :password, on: :member
    patch :update_password, on: :member
    post :link_oidc, on: :member
    delete :unlink_oidc, on: :member
    post :api_tokens, to: "profiles#create_api_token"
    delete "api_tokens/:id", to: "profiles#revoke_api_token", as: :api_token
    # Two-factor authentication
    get :two_factor, on: :member
    post :enable_two_factor, on: :member
    delete :disable_two_factor, on: :member
    post :regenerate_backup_codes, on: :member
  end

  # Notifications
  resources :notifications, only: [ :index ] do
    member do
      post :mark_read
    end
    collection do
      post :mark_all_read
      delete :clear_all
    end
  end

  # Requests
  resources :requests, only: [ :index, :show, :new, :create, :destroy ] do
    member do
      get :download
      post :retry
    end
  end

  # User Uploads
  resources :uploads, only: [ :index, :new, :create, :show ]

  # API
  namespace :api, defaults: { format: :json } do
    namespace :v1 do
      get "search", to: "search#index"
      resources :requests, only: [ :index, :create, :show, :destroy ] do
        member do
          post :retry
        end
      end
      resources :users, only: [ :create ]
    end
  end

  # Messaging integrations
  namespace :integrations, defaults: { format: :json } do
    post "telegram/webhook", to: "telegram_webhooks#create"
  end

  # Admin namespace
  namespace :admin do
    root "dashboard#index"
    post "check_updates", to: "dashboard#check_updates"
    post "run_health_check", to: "dashboard#run_health_check"
    resources :users
    resources :uploads, only: [ :index, :new, :create, :show, :destroy ] do
      member do
        post :retry
      end
    end
    resources :download_clients do
      member do
        post :test
        post :move_up
        post :move_down
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
        post :test_hardcover
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

  # Health check for Docker/monitoring
  get "up" => "rails/health#show", as: :rails_health_check
end
