# frozen_string_literal: true

module Admin
  class DownloadClientsController < BaseController
    before_action :set_download_client, only: [:show, :edit, :update, :destroy, :test, :move_up, :move_down]

    def index
      @download_clients = DownloadClientAdministration.ordered
    end

    def show
    end

    def new
      @download_client = DownloadClient.new(category: "")
    end

    def create
      @download_client = DownloadClientAdministration.create(download_client_params)

      if @download_client.persisted?
        redirect_to admin_download_clients_path, notice: "Download client was successfully created."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
    end

    def update
      @api_key_saved = @download_client.api_key.present?
      result = DownloadClientAdministration.update(@download_client, download_client_params)
      @clear_api_key = result.clear_api_key

      if result.saved?
        redirect_to admin_download_clients_path, notice: "Download client was successfully updated."
      else
        # The rejected replacement must not remain in controller/view state.
        # The persisted encrypted value was never changed because the save failed.
        @download_client.api_key = nil
        if result.api_key_submitted && !@clear_api_key
          @download_client.errors.add(:api_key, "replacement was not saved; re-enter it after correcting the other errors")
        end
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      DownloadClientAdministration.destroy(@download_client)
      redirect_to admin_download_clients_path, notice: "Download client was successfully deleted."
    end

    def test
      outcome = DownloadClientAdministration.test(@download_client)
      if outcome.success?
        redirect_to admin_download_clients_path, notice: outcome.message
      else
        redirect_to admin_download_clients_path, alert: outcome.message
      end
    end

    def move_up
      DownloadClientAdministration.move(@download_client, :up)
      redirect_to admin_download_clients_path
    end

    def move_down
      DownloadClientAdministration.move(@download_client, :down)
      redirect_to admin_download_clients_path
    end

    private

    def set_download_client
      @download_client = DownloadClient.find(params[:id])
    end

    def download_client_params
      params.require(:download_client).permit(*DownloadClientAdministration::ATTRIBUTES)
    end
  end
end
