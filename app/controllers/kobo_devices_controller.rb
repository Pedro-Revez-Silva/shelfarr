# frozen_string_literal: true

class KoboDevicesController < ApplicationController
  before_action :open_warm_page, only: %i[index show]

  def index
    @devices = Current.user.kobo_devices.order(:name)
    base_url = request.base_url + request.script_name
    # New readers keep their Kobo Store by default where that is possible.
    # Receiving Shelfarr places stays off until physical-reader acceptance.
    @device = Current.user.kobo_devices.new(base_url: base_url, share_progress: true, receive_progress: false,
      store_coexistence: URI.parse(base_url).scheme == "https")
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
    # The same bounded evaluation the next sync runs, so the page says what
    # that sync will send. It is idempotent and never changes reading times.
    Kobo::OutboundProgress.refresh(@device)
    load_deliveries
  end

  def update
    @device = Current.user.kobo_devices.find(params[:id])
    was_coexisting = @device.store_coexistence?
    was_receiving = @device.receive_progress?
    if @device.update(params.require(:kobo_device).permit(:store_coexistence, :share_progress, :receive_progress))
      redirect_to kobo_device_path(@device), notice: helpers.kobo_settings_notice(@device, was_coexisting: was_coexisting, was_receiving: was_receiving)
    else
      load_deliveries
      render :show, status: :unprocessable_entity
    end
  end

  # An explicit choice of the Kobo place over the saved Shelfarr place.
  def use_kobo_place
    device = Current.user.kobo_devices.find(params[:id])
    delivery = device.kobo_deliveries.find_by!(entitlement_id: params[:entitlement_id].to_s)
    Kobo::ProgressBridge.new(delivery).choose!
    redirect_to kobo_device_path(device), notice: helpers.kobo_place_chosen_notice(delivery)
  rescue Kobo::ProgressBridge::NothingToChoose
    redirect_to kobo_device_path(device), alert: KoboDevicesHelper::KOBO_PLACE_REFUSALS.fetch(:nothing_to_choose)
  rescue Consumer::ProgressWriter::Conflict
    redirect_to kobo_device_path(device), alert: KoboDevicesHelper::KOBO_PLACE_REFUSALS.fetch(:conflict)
  rescue Consumer::ProgressWriter::Invalid
    redirect_to kobo_device_path(device), alert: KoboDevicesHelper::KOBO_PLACE_REFUSALS.fetch(:invalid)
  end

  # An explicit choice to send Shelfarr's place although it could not be
  # compared with this reader's place automatically.
  def send_shelfarr_place
    device = Current.user.kobo_devices.find(params[:id])
    delivery = device.kobo_deliveries.find_by!(entitlement_id: params[:entitlement_id].to_s)
    Kobo::OutboundProgress.choose_for!(delivery)
    redirect_to kobo_device_path(device), notice: helpers.kobo_shelfarr_place_notice(device, delivery)
  rescue Kobo::OutboundProgress::NothingToSend
    redirect_to kobo_device_path(device), alert: KoboDevicesHelper::KOBO_SHELFARR_PLACE_REFUSAL
  end

  def rotate
    @device = Current.user.kobo_devices.find(params[:id])
    show_setup(@device.rotate_token!)
  end

  def destroy
    Current.user.kobo_devices.find(params[:id]).destroy!
    redirect_to kobo_devices_path, notice: KoboDevicesHelper::KOBO_REVOKED_NOTICE
  end

  def send_book
    device = Current.user.kobo_devices.find(params[:id])
    book = Book.acquired.find(params[:book_id])
    delivery = device.send_book!(book)
    redirect_to library_path(book), notice: helpers.kobo_queued_notice(device, delivery)
  rescue KoboPublication::Unavailable => error
    redirect_to library_path(book), alert: error.message
  end

  private

  def device_params
    params.require(:kobo_device).permit(:name, :base_url, :store_coexistence, :share_progress, :receive_progress)
  end

  def load_deliveries
    @deliveries = @device.kobo_deliveries.includes(:book, :kobo_account_book_file, kobo_account_book: { kobo_account: :user })
      .order(updated_at: :desc)
    @progresses = Current.user.consumer_progresses.where(book_id: @deliveries.map(&:book_id).compact).index_by(&:book_id)
  end

  def open_warm_page
    return unless flash.empty? && WebPreview::Access.current.allows?(Current.user) && WarmEntry.stylesheet_built?

    if action_name == "index"
      redirect_to web_preview_account_section_path(section: "devices", anchor: "kobo-readers")
    else
      redirect_to web_preview_kobo_reader_path(Current.user.kobo_devices.find(params[:id]))
    end
  end

  def show_setup(token)
    @endpoint = @device.endpoint(token)
    response.headers["Cache-Control"] = "private, no-store"
    response.headers["Referrer-Policy"] = "no-referrer"
    render :setup
  end
end
