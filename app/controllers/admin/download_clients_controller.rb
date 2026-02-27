# frozen_string_literal: true

module Admin
  class DownloadClientsController < BaseController
    before_action :set_download_client, only: [:show, :edit, :update, :destroy, :test, :move_up, :move_down]

    def index
      @download_clients = DownloadClient.order(client_type: :asc, priority: :asc)
    end

    def show
    end

    def new
      @download_client = DownloadClient.new(category: "shelfarr")
    end

    def create
      @download_client = DownloadClient.new(download_client_params)
      @download_client.priority = next_priority_for(@download_client.client_type)

      if @download_client.save
        run_download_client_health_check
        redirect_to admin_download_clients_path, notice: "Download client was successfully created."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
    end

    def update
      update_params = download_client_params
      # Don't overwrite password/api_key if left blank
      update_params = update_params.except(:password) if update_params[:password].blank?
      update_params = update_params.except(:api_key) if update_params[:api_key].blank?

      if @download_client.update(update_params)
        run_download_client_health_check
        redirect_to admin_download_clients_path, notice: "Download client was successfully updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @download_client.destroy
      run_download_client_health_check
      redirect_to admin_download_clients_path, notice: "Download client was successfully deleted."
    end

    def test
      success = @download_client.test_connection
      run_download_client_health_check

      if success
        redirect_to admin_download_clients_path, notice: "Connection to '#{@download_client.name}' successful!"
      else
        redirect_to admin_download_clients_path, alert: "Connection to '#{@download_client.name}' failed."
      end
    end

    def move_up
      swap_priority(:up)
      redirect_to admin_download_clients_path
    end

    def move_down
      swap_priority(:down)
      redirect_to admin_download_clients_path
    end

    private

    def set_download_client
      @download_client = DownloadClient.find(params[:id])
    end

    def download_client_params
      params.require(:download_client).permit(:name, :client_type, :url, :username, :password, :api_key, :category, :download_path, :enabled)
    end

    def next_priority_for(client_type)
      max = DownloadClient.where(client_type: client_type).maximum(:priority) || -1
      max + 1
    end

    def swap_priority(direction)
      same_type_clients = DownloadClient.where(client_type: @download_client.client_type).order(priority: :asc).to_a
      index = same_type_clients.index(@download_client)
      return unless index

      swap_index = direction == :up ? index - 1 : index + 1
      return if swap_index < 0 || swap_index >= same_type_clients.length

      other = same_type_clients[swap_index]
      @download_client.priority, other.priority = other.priority, @download_client.priority
      @download_client.save!
      other.save!
    end

    def run_download_client_health_check
      HealthCheckJob.perform_now(service: "download_client")
    rescue => e
      Rails.logger.warn "[DownloadClientsController] Failed to run download client health check: #{e.message}"
    end
  end
end
