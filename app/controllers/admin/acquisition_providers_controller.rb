# frozen_string_literal: true

module Admin
  class AcquisitionProvidersController < BaseController
    before_action :set_provider, only: [ :show, :edit, :update, :destroy, :test ]
    before_action :open_warm_page, only: [ :index, :new, :show, :edit ]

    def index
      @providers = AcquisitionProvider.by_priority
    end

    def show
    end

    def new
      @provider = AcquisitionProvider.new(AcquisitionProvider::FORM_DEFAULTS)
    end

    def create
      @provider = AcquisitionProvider.new(provider_params)
      @provider.priority = AcquisitionProvider.next_priority

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
      if RemoteResult.succeeded?(@provider.test_connection)
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

    def open_warm_page
      return unless request.get? && flash.empty? && WebPreview::Access.current.allows?(Current.user) && WarmEntry.stylesheet_built?

      redirect_to web_preview_server_category_path(category: "sources", anchor: warm_anchor)
    end

    def warm_anchor
      case action_name
      when "index" then "acquisition_providers"
      when "new" then "acquisition_providers-new"
      when "show" then "acquisition-provider-#{@provider.id}"
      else "acquisition-provider-#{@provider.id}-edit"
      end
    end
  end
end
