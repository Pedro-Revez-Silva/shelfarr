# frozen_string_literal: true

class KoboDevicesController < ApplicationController
  def index
    @devices = Current.user.kobo_devices.order(:name)
    base_url = request.base_url + request.script_name
    # New readers keep their Kobo Store by default where that is possible.
    @device = Current.user.kobo_devices.new(base_url: base_url, share_progress: true,
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
    load_deliveries
  end

  def update
    @device = Current.user.kobo_devices.find(params[:id])
    was_coexisting = @device.store_coexistence?
    if @device.update(params.require(:kobo_device).permit(:store_coexistence, :share_progress))
      redirect_to kobo_device_path(@device), notice: update_notice(was_coexisting)
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
    redirect_to kobo_device_path(device), notice: "Shelfarr now resumes #{delivery.publication['title']} at the Kobo place."
  rescue Kobo::ProgressBridge::NothingToChoose
    redirect_to kobo_device_path(device), alert: "There is no unapplied Kobo place for this book."
  rescue Consumer::ProgressWriter::Conflict
    redirect_to kobo_device_path(device), alert: "Another device saved a place just now. Review the places and choose again."
  rescue Consumer::ProgressWriter::Invalid
    redirect_to kobo_device_path(device), alert: "That Kobo place belongs to an edition that is no longer in the library."
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
    params.require(:kobo_device).permit(:name, :base_url, :store_coexistence, :share_progress)
  end

  def load_deliveries
    @deliveries = @device.kobo_deliveries.includes(:book, :kobo_account_book_file, kobo_account_book: { kobo_account: :user })
      .order(updated_at: :desc)
    @progresses = Current.user.consumer_progresses.where(book_id: @deliveries.map(&:book_id).compact).index_by(&:book_id)
  end

  def update_notice(was_coexisting)
    if @device.store_coexistence? && !was_coexisting
      "Kobo Store kept on #{@device.name}. Sync the reader over Wi-Fi: your Store library and Shelfarr books both arrive."
    elsif !@device.store_coexistence? && was_coexisting
      "#{@device.name} now syncs Shelfarr books only. Books already on the reader are kept; new Store purchases wait until you restore the original endpoint."
    else
      "Reader settings saved."
    end
  end

  def show_setup(token)
    @endpoint = @device.endpoint(token)
    response.headers["Cache-Control"] = "private, no-store"
    response.headers["Referrer-Policy"] = "no-referrer"
    render :setup
  end
end
