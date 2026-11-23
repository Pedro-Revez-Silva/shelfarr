# frozen_string_literal: true

class WebPreview::Admin::SetupController < WebPreview::Admin::BaseController
  TEXT_KEYS = {
    "prowlarr" => %w[url api_key],
    "qbittorrent" => %w[url username password api_key category],
    "folders" => %w[audiobook_output_path ebook_output_path download_local_path download_remote_path],
    "audiobookshelf/connection" => %w[url api_key],
    "audiobookshelf/libraries" => %w[audiobook_library_id ebook_library_id],
    "search" => []
  }.freeze
  SWITCH_KEYS = { "search" => %w[immediate_search_enabled auto_select_enabled] }.freeze
  SUBMITTED_SECRETS = %w[api_key password].freeze

  def show
    render json: state(params[:step])
  end

  def update
    return render_error("not_found", :not_found) unless known_step?

    step = params[:step]
    values = submitted_values(step)
    return render_error("invalid_request", :bad_request, message: "Send every value of this step, each as text or a switch") if values.nil?

    result = SetupWizard.save(step, values)
    unless result.success?
      render json: { account: web_preview_account_id, error: "setup_rejected", message: redact(result.error, values) }, status: :unprocessable_entity
      return
    end

    following = SetupWizard.step_after_save(step, result)
    render json: {
      account: web_preview_account_id,
      outcome: success(result.notice),
      alert: redact(result.alert.presence, values),
      completed: following.nil?,
      setup: following && state(following, suggest_libraries: result.stay?)
    }
  end

  def skip
    return render_error("not_found", :not_found) unless known_step?

    following = SetupWizard.skip(params[:step], exit_setup: ActiveModel::Type::Boolean.new.cast(params[:exit]) == true)
    render json: { account: web_preview_account_id, completed: following.nil?, setup: following && state(following) }
  end

  def restart
    SetupWizard.restart!
    render json: { account: web_preview_account_id, completed: false, setup: state(SetupWizard::STEPS.first) }
  end

  private

  def state(step, suggest_libraries: false)
    form = SetupWizard::Form.new(step: step, suggest_libraries: suggest_libraries)
    { account: web_preview_account_id, **WebPreview::AdminSetup.new(form).representation }
  end

  def known_step?
    SetupWizard::STEPS.include?(params[:step])
  end

  def submitted_values(step)
    raw = params[:values]
    return unless raw.is_a?(ActionController::Parameters)

    raw = raw.to_unsafe_h
    shape = step == "audiobookshelf" ? "#{step}/#{raw["phase"]}" : step
    texts = TEXT_KEYS[shape]
    switches = SWITCH_KEYS.fetch(shape, [])
    return if texts.nil? || raw.keys.sort != (texts + switches + (step == "audiobookshelf" ? [ "phase" ] : [])).sort
    return unless texts.all? { |key| raw[key].is_a?(String) } && switches.all? { |key| [ true, false ].include?(raw[key]) }

    with_saved_address(step, raw.slice(*texts, *switches, "phase"))
  end

  def with_saved_address(step, values)
    saved = SetupWizard.saved_url(step)
    return values unless values.key?("url") && saved.present? && values["url"] == WebPreview::AdminSetup.mask_address(saved)

    values.merge("url" => saved)
  end

  def redact(text, values)
    WebPreview::AdminSetup.redact(text, values.values_at(*SUBMITTED_SECRETS))
  end
end
