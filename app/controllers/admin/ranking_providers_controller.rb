# frozen_string_literal: true

module Admin
  class RankingProvidersController < BaseController
    before_action :set_provider, only: [ :show, :edit, :update, :destroy, :test ]

    def index
      @providers = RankingProvider.by_priority
    end

    def show
    end

    def new
      @provider = RankingProvider.new(timeout_seconds: 30)
    end

    def create
      @provider = RankingProvider.new(provider_params)
      @provider.priority = next_priority

      if @provider.save
        redirect_to admin_ranking_providers_path, notice: "Ranking provider was successfully created."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
    end

    def update
      attributes = provider_params
      attributes = attributes.except(:api_key) if attributes[:api_key].blank?

      if @provider.update(attributes)
        redirect_to admin_ranking_providers_path, notice: "Ranking provider was successfully updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @provider.destroy
      redirect_to admin_ranking_providers_path, notice: "Ranking provider was successfully deleted."
    end

    def test
      if @provider.test_connection
        redirect_to admin_ranking_providers_path, notice: "Connection to '#{@provider.name}' successful."
      else
        redirect_to admin_ranking_providers_path, alert: "Connection to '#{@provider.name}' failed."
      end
    end

    private

    def set_provider
      @provider = RankingProvider.find(params[:id])
    end

    def provider_params
      params.require(:ranking_provider).permit(
        :name, :url, :api_key, :enabled, :allow_private_network, :timeout_seconds
      )
    end

    def next_priority
      (RankingProvider.maximum(:priority) || -1) + 1
    end
  end
end
