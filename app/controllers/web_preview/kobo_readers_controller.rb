# frozen_string_literal: true

class WebPreview::KoboReadersController < WebPreview::APIController
  SETTINGS = %w[store_coexistence share_progress receive_progress].freeze
  ENTITLEMENT = /\A[0-9A-Za-z-]{1,64}\z/
  SAVED_CONNECTION_ADDRESS = "This reader's saved Shelfarr address is itself a connection address, so a new one can't be made from it. Revoke this reader and connect it again with Shelfarr's own address."
  PLACES_CHANGED = "This book's reading places changed after the page was shown. Review them and choose again."

  before_action :set_device, except: %i[index create book]
  rescue_from ActionDispatch::Http::Parameters::ParseError, with: -> { render_error("invalid_request", :bad_request) }

  def index
    devices = Current.user.kobo_devices.order(:name, :id).to_a
    render json: { account: web_preview_account_id, readers: devices.map { |device| json(device).row }, new_reader: new_reader }
  end

  def create
    values = body_values(%w[name base_url], SETTINGS)
    return render_error("invalid_request", :bad_request) unless values

    @device, token = KoboDevice.issue(user: Current.user, **values.symbolize_keys)
    return render_pasted_connection if KoboDevice.carries_active_connection?(@device.base_url)
    return render_rejection unless @device.save

    render_setup(token, status: :created)
  end

  def show
    Kobo::OutboundProgress.refresh(@device)
    render_reader
  end

  def update
    values = body_values(%w[version], SETTINGS)
    return render_error("invalid_request", :bad_request) unless values

    was_coexisting = @device.store_coexistence?
    was_receiving = @device.receive_progress?
    outcome = @device.with_lock do
      next :changed unless values["version"] == WebPreview::KoboReaderJson.version(@device)

      @device.update(values.slice(*SETTINGS)) ? :saved : :rejected
    end
    case outcome
    when :saved then render_reader(notice: helpers.kobo_settings_notice(@device, was_coexisting: was_coexisting, was_receiving: was_receiving))
    when :rejected then render_rejection
    else render_changed
    end
  end

  def connection_address
    values = body_values(%w[version], [])
    return render_error("invalid_request", :bad_request) unless values

    return render_error("connection_address_saved", :unprocessable_entity, message: SAVED_CONNECTION_ADDRESS) if KoboDevice.carries_active_connection?(@device.base_url)

    token = @device.with_lock do
      @device.rotate_token! if values["version"] == WebPreview::KoboReaderJson.version(@device)
    end
    token ? render_setup(token) : render_changed
  end

  def revoke
    values = body_values(%w[version], [])
    return render_error("invalid_request", :bad_request) unless values

    revoked = @device.with_lock do
      next false unless values["version"] == WebPreview::KoboReaderJson.version(@device)

      @device.destroy!
    end
    return render_changed unless revoked

    render json: { account: web_preview_account_id, revoked: @device.id.to_s, notice: KoboDevicesHelper::KOBO_REVOKED_NOTICE }
  end

  def send_book
    book_id = request.request_parameters["book_id"]
    return render_error("invalid_request", :bad_request) unless book_id.is_a?(String) && book_id.match?(/\A[1-9]\d{0,18}\z/)

    book = Book.acquired.find_by(id: book_id)
    return render_error("book_not_found", :not_found) unless book

    delivery = @device.send_book!(book)
    render json: { account: web_preview_account_id, reader: { id: @device.id.to_s, name: @device.name }, notice: helpers.kobo_queued_notice(@device, delivery) }
  rescue KoboPublication::Unavailable => error
    render_error("kobo_send_refused", :unprocessable_entity, message: error.message)
  end

  def use_kobo_place
    notice = with_shown_delivery do |delivery|
      Kobo::ProgressBridge.new(delivery).choose!
      helpers.kobo_place_chosen_notice(delivery)
    end
    render_reader(notice: notice) if notice
  rescue Kobo::ProgressBridge::NothingToChoose
    render_place_refusal(KoboDevicesHelper::KOBO_PLACE_REFUSALS.fetch(:nothing_to_choose))
  rescue Consumer::ProgressWriter::Conflict
    render_place_refusal(KoboDevicesHelper::KOBO_PLACE_REFUSALS.fetch(:conflict))
  rescue Consumer::ProgressWriter::Invalid
    render_place_refusal(KoboDevicesHelper::KOBO_PLACE_REFUSALS.fetch(:invalid))
  end

  def send_shelfarr_place
    notice = with_shown_delivery do |delivery|
      Kobo::OutboundProgress.choose_for!(delivery)
      helpers.kobo_shelfarr_place_notice(@device, delivery)
    end
    render_reader(notice: notice) if notice
  rescue Kobo::OutboundProgress::NothingToSend
    render_place_refusal(KoboDevicesHelper::KOBO_SHELFARR_PLACE_REFUSAL)
  end

  def book
    raise ActiveRecord::RecordNotFound unless params[:id].is_a?(String) && params[:id].match?(/\A[1-9]\d{0,18}\z/)

    book = Book.acquired.find(params[:id])
    readers = Current.user.kobo_devices.order(:name, :id).map { |device| { id: device.id.to_s, name: device.name } }
    render json: { account: web_preview_account_id, kobo: { readers: readers, refusal: KoboPublication.new(book).send_refusal } }
  end

  private

  def set_device
    raise ActiveRecord::RecordNotFound unless params[:id].is_a?(String) && params[:id].match?(/\A[1-9]\d{0,18}\z/)

    @device = Current.user.kobo_devices.find_by(id: params[:id])
    render_error("reader_not_found", :not_found) unless @device
  end

  def body_values(strings, booleans)
    body = request.request_parameters
    values = (strings + booleans).index_with { |field| body[field] }
    return unless strings.all? { |field| values[field].is_a?(String) }
    return unless booleans.all? { |field| [ true, false ].include?(values[field]) }

    values
  end

  def with_shown_delivery
    values = body_values(%w[entitlement_id choice], [])
    unless values && values["entitlement_id"].match?(ENTITLEMENT)
      render_error("invalid_request", :bad_request)
      return
    end
    @device.with_lock do
      delivery = @device.kobo_deliveries.find_by(entitlement_id: values["entitlement_id"])
      unless delivery
        render_place_refusal("This book is no longer selected for #{@device.name}. Review the list again.")
        next
      end
      progress = delivery.book_id && @device.user.consumer_progresses.find_by(book_id: delivery.book_id)
      unless values["choice"] == WebPreview::KoboReaderJson.choice(delivery, progress)
        render_place_refusal(PLACES_CHANGED)
        next
      end
      yield delivery
    end
  end

  def new_reader
    base_url = request.base_url + request.script_name
    { base_url: base_url, store_coexistence: URI.parse(base_url).scheme == "https", share_progress: true, receive_progress: false }
  end

  def json(device)
    WebPreview::KoboReaderJson.new(device, view: helpers)
  end

  def render_reader(notice: nil, status: :ok)
    render json: { account: web_preview_account_id, reader: json(@device).detail, notice: notice }.compact, status: status
  end

  def render_setup(token, status: :ok)
    headers["Referrer-Policy"] = "no-referrer"
    render json: { account: web_preview_account_id, reader: json(@device).row, setup: json(@device).setup(token) }, status: status
  end

  def render_rejection
    render json: { account: web_preview_account_id, error: "invalid_reader", errors: @device.errors.to_hash, messages: @device.errors.full_messages }, status: :unprocessable_entity
  end

  def render_pasted_connection
    @device.errors.add(:base_url, "must be Shelfarr's own address, not a Kobo connection address")
    render_rejection
  end

  def render_changed
    Kobo::OutboundProgress.refresh(@device.reload)
    render json: { account: web_preview_account_id, error: "reader_changed", reader: json(@device).detail }, status: :conflict
  end

  def render_place_refusal(message)
    Kobo::OutboundProgress.refresh(@device.reload)
    render json: { account: web_preview_account_id, error: "place_refused", message: message, reader: json(@device).detail }, status: :conflict
  end
end
