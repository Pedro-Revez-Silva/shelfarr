# frozen_string_literal: true

class WebPreview::Admin::DownloadsController < WebPreview::Admin::BaseController
  IDENTIFIER = /\A[1-9]\d{0,18}\z/
  RULE_ATTRIBUTES = %i[provider indexer_name download_type download_client_id enabled].freeze
  SCALARS = [ String, Integer, TrueClass, FalseClass, NilClass ].freeze
  SWITCHES = %w[enabled].freeze
  SWITCH_VALUES = [ true, false, "true", "false", "1", "0", 1, 0 ].freeze
  NUMBERS = %w[torrent_verification_max_attempts torrent_verification_wait_time].freeze
  LARGEST_NUMBER = 9_007_199_254_740_991

  class Stale < StandardError; end
  class Malformed < StandardError; end
  class Oversized < StandardError; end

  rescue_from Stale, with: :render_stale
  rescue_from Oversized, with: ->(error) { render_rejected(error.message.to_sym => "must be #{LARGEST_NUMBER} or less") }
  rescue_from Malformed, ActionController::ParameterMissing, with: ->(error) { render_error("invalid_request", :bad_request, message: error.message) }

  def show
    render json: answer
  end

  def create_client
    attributes = submitted(:client, DownloadClientAdministration::ATTRIBUTES)
    return render_rejected(client_type: "is not a supported client type") unless supported_type?(attributes[:client_type])

    client = DownloadClientAdministration.create(attributes)
    return render_rejected_record(client) unless client.persisted?

    render json: answer(outcome: success("Download client “#{client.name}” added."), created: client.id.to_s), status: :created
  rescue ActiveRecord::RecordNotUnique
    render_rejected(name: "has already been taken")
  end

  def update_client
    client = find(DownloadClient)
    attributes = submitted(:client, DownloadClientAdministration::ATTRIBUTES)
    return render_rejected(client_type: "is not a supported client type") if attributes.key?(:client_type) && !supported_type?(attributes[:client_type])

    result = DownloadClient.transaction do
      current!(client)
      DownloadClientAdministration.apply_update(client, attributes)
    end
    return render_rejected_record(client, replacement_dropped: result.api_key_submitted && !result.clear_api_key) unless result.saved?

    DownloadClientAdministration.settle
    render json: answer(outcome: success(client.saved_changes.any? ? "Download client “#{client.name}” saved." : "There were no changes to save."))
  rescue ActiveRecord::RecordNotUnique
    render_rejected(name: "has already been taken")
  end

  def destroy_client
    client = find(DownloadClient)
    confirmed = confirmed_rules
    removed_rules = 0
    DownloadClient.transaction do
      current!(client)
      present = client.download_routing_rules.pluck(:id).map(&:to_s).sort
      raise Stale unless present == confirmed

      removed_rules = present.size
      client.destroy!
    end
    DownloadClientAdministration.settle
    render json: answer(outcome: success(removal_message(client, removed_rules)))
  end

  def test_client
    client = find(DownloadClient)
    outcome = DownloadClientAdministration.test(client)
    render json: answer(outcome: outcome_answer(outcome), tested: client.id.to_s)
  end

  def move_client
    client = find(DownloadClient)
    direction = params[:direction].to_s
    raise Malformed, "Choose up or down" unless %w[up down].include?(direction)

    neighbour = params[:neighbour]
    raise Malformed, "Send the client you are moving past" unless neighbour.is_a?(String) && neighbour.match?(IDENTIFIER)

    result = DownloadClient.transaction do
      current!(client)
      DownloadClientAdministration.move(client, direction.to_sym, expected_neighbour: neighbour)
    end
    raise Stale if result == :stale
    outcome = case result
    when :moved then success("“#{client.name}” moved #{direction}.")
    when :tied then failure("“#{client.name}” has the same priority as the client #{direction == 'up' ? 'above' : 'below'} it, so the order between them cannot be changed. Nothing was moved.")
    else failure("“#{client.name}” cannot move #{direction}. Nothing was moved.")
    end
    render json: answer(outcome: outcome, moved: outcome[:tone] == "success")
  end

  def create_rule
    rule = DownloadRoutingRule.new(rule_attributes)
    return render_rejected_record(rule) unless rule.save

    render json: answer(outcome: success("Routing rule for “#{rule.indexer_name}” added."), created: rule.id.to_s), status: :created
  rescue ActiveRecord::RecordNotUnique
    render_rejected(indexer_name: "already has a rule for this source and download type")
  end

  def update_rule
    rule = find(DownloadRoutingRule)
    attributes = rule_attributes
    saved = DownloadRoutingRule.transaction do
      current!(rule)
      rule.update(attributes)
    end
    return render_rejected_record(rule) unless saved

    render json: answer(outcome: success(rule.saved_changes.any? ? "Routing rule for “#{rule.indexer_name}” saved." : "There were no changes to save."))
  rescue ActiveRecord::RecordNotUnique
    render_rejected(indexer_name: "already has a rule for this source and download type")
  end

  def destroy_rule
    rule = find(DownloadRoutingRule)
    DownloadRoutingRule.transaction do
      current!(rule)
      rule.destroy!
    end
    render json: answer(outcome: success("Routing rule for “#{rule.indexer_name}” removed."))
  end

  private

  def presenter
    @presenter ||= WebPreview::DownloadManagement.new
  end

  def answer(**extra)
    { account: web_preview_account_id, **presenter.representation, **extra }
  end

  def find(model)
    id = params[:id].to_s
    raise ActiveRecord::RecordNotFound unless id.match?(IDENTIFIER)

    model.find(id)
  end

  def current!(record)
    expected = params[:version]
    raise Malformed, "Send the version you are changing" unless expected.is_a?(String) && expected.present?

    record.reload
    raise Stale unless WebPreview::DownloadManagement.version(record) == expected
  end

  def submitted(name, allowed)
    raw = params.require(name)
    raise Malformed, "Send the #{name} as an object of names and values" unless raw.is_a?(ActionController::Parameters)

    values = raw.to_unsafe_h.slice(*allowed.map(&:to_s))
    malformed = values.reject { |_, value| SCALARS.any? { |type| value.is_a?(type) } }.keys
    raise Malformed, "These values must be text, numbers or switches: #{malformed.join(', ')}" if malformed.any?

    oversized = NUMBERS.select { |key| values[key].to_s.strip.match?(/\A[+-]?\d+\z/) && values[key].to_s.to_i.abs > LARGEST_NUMBER }
    raise Oversized, oversized.first if oversized.any?

    unset = SWITCHES.select { |key| values.key?(key) && !SWITCH_VALUES.include?(values[key]) }
    raise Malformed, "These switches must be on or off: #{unset.join(', ')}" if unset.any?

    values.to_h.symbolize_keys
  end

  def outcome_answer(outcome)
    { tone: outcome.success? ? "success" : "error", message: outcome.summary }
  end

  def confirmed_rules
    ids = params[:rules]
    raise Malformed, "Send the routing rules you confirmed removing" unless ids.is_a?(Array) && ids.all? { |id| id.is_a?(String) && id.match?(IDENTIFIER) }

    ids.sort
  end

  def rule_attributes
    attributes = submitted(:rule, RULE_ATTRIBUTES)
    return attributes unless attributes.key?(:download_client_id)

    client_id = attributes[:download_client_id].to_s
    attributes.merge(download_client_id: client_id.match?(IDENTIFIER) ? client_id : nil)
  end

  def supported_type?(type)
    DownloadClient.client_types.key?(type.to_s)
  end

  def removal_message(client, removed_rules)
    rules = removed_rules.zero? ? "" : " with its #{removed_rules == 1 ? 'routing rule' : "#{removed_rules} routing rules"}"
    "Download client “#{client.name}” removed#{rules}."
  end

  def render_rejected_record(record, replacement_dropped: false)
    errors = record.errors.map { |error| { field: error.attribute.to_s, message: error.full_message } }
    errors << { field: "api_key", message: "The new API key was not saved; enter it again after correcting the other fields." } if replacement_dropped
    render json: { account: web_preview_account_id, error: "invalid_record", errors: errors }, status: :unprocessable_entity
  end

  def render_rejected(**messages)
    errors = messages.map { |field, message| { field: field.to_s, message: "#{field.to_s.humanize} #{message}" } }
    render json: { account: web_preview_account_id, error: "invalid_record", errors: errors }, status: :unprocessable_entity
  end

  def render_stale
    render json: { account: web_preview_account_id, error: "download_changed", **presenter.representation }, status: :conflict
  end
end
