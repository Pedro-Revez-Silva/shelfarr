# frozen_string_literal: true

class WebPreview::Admin::AcquisitionProvidersController < WebPreview::Admin::BaseController
  IDENTIFIER = /\A[1-9]\d{0,18}\z/
  TEXTS = %w[name url api_key].freeze
  SWITCHES = %w[enabled allow_private_network supports_ebooks supports_audiobooks supports_comicbooks].freeze
  NUMBERS = %w[timeout_seconds].freeze
  ATTRIBUTES = (TEXTS + SWITCHES + NUMBERS).freeze
  SWITCH_VALUES = [ true, false, "true", "false", "1", "0" ].freeze
  FIELD_LABELS = { "url" => "Address", "api_key" => "Bearer token", "timeout_seconds" => "Timeout" }.freeze
  PRIVATE_ADDRESS = /resolves to a private address/
  BLOCKED_ADDRESS = /resolves to a blocked address|must be a valid http or https URL|Invalid URL/
  UNRESOLVED_ADDRESS = /Could not resolve/

  class Stale < StandardError; end
  class Malformed < StandardError; end
  class Forbidden < StandardError; end

  rescue_from Stale, with: :render_stale
  rescue_from Forbidden, with: -> { render_error("not_found", :not_found) }
  rescue_from Malformed, with: ->(error) { render_error("invalid_request", :bad_request, message: error.message) }
  rescue_from ActionDispatch::Http::Parameters::ParseError, with: -> { render_error("invalid_request", :bad_request) }

  def show
    render json: answer
  end

  def create
    provider = AcquisitionProvider.new(submitted)
    saved = AcquisitionProvider.transaction do
      raise Forbidden unless acting_administrator?

      provider.priority = AcquisitionProvider.next_priority
      without_database_debug_log { provider.save }
    end
    return render_rejected_record(provider) unless saved

    render json: answer(outcome: success("Provider “#{provider.name}” added."), created: provider.id.to_s), status: :created
  rescue ActiveRecord::RecordNotUnique
    render_rejected(name: "has already been taken")
  end

  def update
    provider = find
    expected = expected_version
    attributes = submitted
    attributes.delete("api_key") if attributes["api_key"].blank?
    saved = AcquisitionProvider.transaction do
      current!(provider, expected)
      without_database_debug_log { provider.update(attributes) }
    end
    return render_rejected_record(provider) unless saved

    render json: answer(outcome: success(provider.saved_changes.any? ? "Provider “#{provider.name}” saved." : "There were no changes to save."))
  rescue ActiveRecord::RecordNotUnique
    render_rejected(name: "has already been taken")
  end

  def destroy
    provider = find
    expected = expected_version
    AcquisitionProvider.transaction do
      current!(provider, expected)
      provider.destroy!
    end
    render json: answer(outcome: success("Provider “#{provider.name}” removed."))
  end

  def test
    provider = find
    raise Forbidden unless acting_administrator?

    render json: answer(outcome: test_outcome(provider), tested: provider.id.to_s)
  end

  private

  def process_action(*)
    read_body_without_debug_log
    super
  end

  def read_body_without_debug_log
    quietly(request.logger) { request.request_parameters }
  rescue ActionDispatch::Http::Parameters::ParseError
    nil
  end

  def without_database_debug_log(&block)
    quietly(ActiveRecord::Base.logger, &block)
  end

  def quietly(logger, &block)
    return yield unless logger.respond_to?(:silence)

    logger.silence(Logger::INFO, &block)
  end

  def presenter
    @presenter ||= WebPreview::AcquisitionProviders.new
  end

  def answer(**extra)
    { account: web_preview_account_id, **presenter.representation, **extra }
  end

  def body
    request.request_parameters
  end

  def find
    id = params[:id].to_s
    raise ActiveRecord::RecordNotFound unless id.match?(IDENTIFIER)

    AcquisitionProvider.find(id)
  end

  def acting_administrator?
    User.active.admin.exists?(id: Current.user.id)
  end

  def expected_version
    version = body["version"]
    raise Malformed, "Send the version you are changing" unless version.is_a?(String) && version.present?

    version
  end

  def current!(provider, expected)
    raise Forbidden unless acting_administrator?

    provider.lock!
    raise Stale unless WebPreview::AcquisitionProviders.version(provider) == expected
  end

  def submitted
    raw = body["provider"]
    raise Malformed, "Send the provider as an object of names and values" unless raw.is_a?(Hash)

    values = raw.slice(*ATTRIBUTES)
    wrong_text = TEXTS.select { |key| values.key?(key) && !values[key].is_a?(String) }
    wrong_switch = SWITCHES.select { |key| values.key?(key) && !SWITCH_VALUES.include?(values[key]) }
    wrong_number = NUMBERS.select { |key| values.key?(key) && !(values[key].is_a?(Integer) || values[key].is_a?(String)) }
    wrong = wrong_text + wrong_switch + wrong_number
    raise Malformed, "These values have the wrong type: #{wrong.join(', ')}" if wrong.any?

    values
  end

  def test_outcome(provider)
    result = provider.test_connection
    return { tone: "success", message: "Connection successful." } if RemoteResult.succeeded?(result)

    { tone: "error", message: "Connection failed: #{failure_reason(result)}." }
  rescue StandardError => error
    Rails.logger.warn "[WebPreview::Admin::AcquisitionProvidersController] Provider test failed: #{error.class}"
    { tone: "error", message: "Connection failed: the provider did not answer as expected." }
  end

  def failure_reason(result)
    return "the health check did not answer with success" unless RemoteResult.failed?(result)

    error = result.error
    message = error.message.to_s
    return "the address is on a private network. Turn on Allow private network if this provider runs on your local network" if message.match?(PRIVATE_ADDRESS)
    return "Shelfarr does not contact that address" if message.match?(BLOCKED_ADDRESS)
    return ConnectionErrorClassifier::MESSAGES.fetch(:dns) if message.match?(UNRESOLVED_ADDRESS)

    ConnectionErrorClassifier.classify(error)&.message || "the provider could not be reached"
  end

  def render_rejected_record(provider)
    errors = provider.errors.map { |error| { field: error.attribute.to_s, message: field_message(error) } }
    render json: { account: web_preview_account_id, error: "invalid_record", errors: errors }, status: :unprocessable_entity
  end

  def field_message(error)
    label = FIELD_LABELS[error.attribute.to_s]
    label ? "#{label} #{error.message}" : error.full_message
  end

  def render_rejected(**messages)
    errors = messages.map { |field, message| { field: field.to_s, message: "#{field.to_s.humanize} #{message}" } }
    render json: { account: web_preview_account_id, error: "invalid_record", errors: errors }, status: :unprocessable_entity
  end

  def render_stale
    render json: { account: web_preview_account_id, error: "provider_changed", **presenter.representation }, status: :conflict
  end
end
