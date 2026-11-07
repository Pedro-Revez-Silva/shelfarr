# frozen_string_literal: true

class KoboDevicesController < ApplicationController
  def index
    @devices = Current.user.kobo_devices.order(:name)
    @device = Current.user.kobo_devices.new(base_url: request.base_url + request.script_name)
  end

  def create
    @device, token = KoboDevice.issue(user: Current.user, **device_params.to_h.symbolize_keys)
    if @device.save
      show_setup(token)
    else
      @devices = Current.user.kobo_devices.order(:name)
      render :index, status: :unprocessable_entity
    end
  end

  def show
    @device = Current.user.kobo_devices.find(params[:id])
    @deliveries = @device.kobo_deliveries.includes(:book).order(updated_at: :desc)
  end

  def rotate
    @device = Current.user.kobo_devices.find(params[:id])
    show_setup(@device.rotate_token!)
  end

  def destroy
    Current.user.kobo_devices.find(params[:id]).destroy!
    redirect_to kobo_devices_path, notice: "Kobo connection revoked. Books already on the reader are kept."
  end

  def send_book
    device = Current.user.kobo_devices.find(params[:id])
    book = Book.acquired.find(params[:book_id])
    device.send_book!(book)
    redirect_to library_path(book), notice: "Queued for #{device.name}. Sync your Kobo over Wi-Fi to download it."
  rescue KoboPublication::Unavailable => error
    redirect_to library_path(book), alert: error.message
  end

  private

  def device_params
    params.require(:kobo_device).permit(:name, :base_url)
  end

  def show_setup(token)
    @endpoint = @device.endpoint(token)
    response.headers["Cache-Control"] = "private, no-store"
    response.headers["Referrer-Policy"] = "no-referrer"
    render :setup
  end
end
