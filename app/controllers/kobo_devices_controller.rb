# frozen_string_literal: true

class KoboDevicesController < ApplicationController
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
      redirect_to kobo_device_path(@device), notice: update_notice(was_coexisting, was_receiving)
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

  # An explicit choice to send Shelfarr's place although it could not be
  # compared with this reader's place automatically.
  def send_shelfarr_place
    device = Current.user.kobo_devices.find(params[:id])
    delivery = device.kobo_deliveries.find_by!(entitlement_id: params[:entitlement_id].to_s)
    progress = Kobo::OutboundProgress.progresses_for(device, [ delivery ])[delivery.book_id]
    raise Kobo::OutboundProgress::NothingToSend unless Kobo::OutboundProgress.new(delivery, progress).choose!

    redirect_to kobo_device_path(device), notice: "#{device.name} moves #{delivery.publication['title']} to the Shelfarr place at its next Wi-Fi sync."
  rescue Kobo::OutboundProgress::NothingToSend
    redirect_to kobo_device_path(device), alert: "There is no Shelfarr place waiting for a choice for this book. Its place may have changed; review it again."
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
    delivery = device.send_book!(book)
    edition = " as a Kobo edition (KEPUB) prepared from this EPUB; the library file is unchanged" if delivery.kepub_copy?
    redirect_to library_path(book), notice: "Queued for #{device.name}#{edition}. Sync your Kobo over Wi-Fi to download it."
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

  def update_notice(was_coexisting, was_receiving)
    if @device.receive_progress? && !was_receiving
      "#{@device.name} receives Shelfarr reading places for books sent from your library at its next Wi-Fi sync."
    elsif !@device.receive_progress? && was_receiving
      "#{@device.name} no longer receives Shelfarr reading places. Places it already has stay on the reader."
    elsif @device.store_coexistence? && !was_coexisting
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
