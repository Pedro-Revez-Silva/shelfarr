# frozen_string_literal: true

module Admin
  class AcquisitionProvidersController < BaseController
    before_action :set_provider, only: [ :show, :edit, :update, :destroy, :test ]

    def index
      @providers = AcquisitionProvider.by_priority
    end

    def show
    end

    def new
      @provider = AcquisitionProvider.new(timeout_seconds: 30, supports_ebooks: true, supports_audiobooks: true, supports_comicbooks: false)
    end

    def create
      @provider = AcquisitionProvider.new(provider_params)
      @provider.priority = next_priority

      if @provider.save
        redirect_to admin_acquisition_providers_path, notice: "Acquisition provider was successfully created."
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
        redirect_to admin_acquisition_providers_path, notice: "Acquisition provider was successfully updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @provider.destroy
      redirect_to admin_acquisition_providers_path, notice: "Acquisition provider was successfully deleted."
    end

    def test
      if @provider.test_connection
        redirect_to admin_acquisition_providers_path, notice: "Connection to '#{@provider.name}' successful."
      else
        redirect_to admin_acquisition_providers_path, alert: "Connection to '#{@provider.name}' failed."
      end
    end

    private

    def set_provider
      @provider = AcquisitionProvider.find(params[:id])
    end

    def provider_params
      params.require(:acquisition_provider).permit(
        :name, :url, :api_key, :enabled, :allow_private_network, :supports_ebooks, :supports_audiobooks, :supports_comicbooks, :timeout_seconds
      )
    end

    def next_priority
      (AcquisitionProvider.maximum(:priority) || -1) + 1
    end
  end
end
