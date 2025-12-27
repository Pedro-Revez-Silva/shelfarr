Rails.application.routes.draw do
  # Authentication
  resource :session do
    get :verify_otp, on: :member
    post :submit_otp, on: :member
  end
  get "sign_up", to: "registrations#new", as: :sign_up
  post "sign_up", to: "registrations#create"

  # Main application
  root "dashboard#index"

  # Search
  get "search", to: "search#index"
  get "search/results", to: "search#results"

  # Library
  resources :library, only: [:index, :show]

  # Profile
  resource :profile, only: [:show, :edit, :update] do
    get :password, on: :member
    patch :update_password, on: :member
    # Two-factor authentication
    get :two_factor, on: :member
    post :enable_two_factor, on: :member
    delete :disable_two_factor, on: :member
    post :regenerate_backup_codes, on: :member
  end

  # Notifications
  resources :notifications, only: [:index] do
    member do
      post :mark_read
    end
    collection do
      post :mark_all_read
    end
  end

  # Requests
  resources :requests, only: [:index, :show, :new, :create, :destroy] do
    member do
      get :download
    end
  end

  # Admin namespace
  namespace :admin do
    root "dashboard#index"
    post "check_updates", to: "dashboard#check_updates"
    resources :users
    resources :uploads, only: [:index, :new, :create, :show, :destroy] do
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
    resources :settings, only: [:index, :update] do
      collection do
        patch :bulk_update
      end
    end
    resources :issues, only: [:index] do
      member do
        post :retry
        post :cancel
      end
    end
    resource :bulk_operations, only: [] do
      post :retry_selected
      post :cancel_selected
      post :retry_all
    end
    resources :activity_logs, only: [:index]
    resources :requests, only: [] do
      resources :search_results, only: [:index] do
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
