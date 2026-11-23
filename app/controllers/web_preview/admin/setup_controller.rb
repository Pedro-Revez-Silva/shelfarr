# frozen_string_literal: true

class WebPreview::Admin::SetupController < WebPreview::Admin::BaseController
  SUBMITTED_KEYS = %i[
    url api_key username password category phase
    audiobook_output_path ebook_output_path download_local_path download_remote_path
    audiobook_library_id ebook_library_id
    immediate_search_enabled auto_select_enabled
  ].freeze

  def show
    render json: state(params[:step])
  end

  def update
    return render_error("not_found", :not_found) unless known_step?
    return render_error("invalid_request", :bad_request, message: "Send the step's values as an object") unless submitted_object?

    step = params[:step]
    result = SetupWizard.save(step, submitted_values)
    unless result.success?
      render json: { account: web_preview_account_id, error: "setup_rejected", message: WebPreview::SecretRedaction.call(result.error) }, status: :unprocessable_entity
      return
    end

    following = SetupWizard.step_after_save(step, result)
    render json: {
      account: web_preview_account_id,
      outcome: success(result.notice),
      alert: WebPreview::SecretRedaction.call(result.alert.presence),
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

  def submitted_object?
    params[:values].nil? || params[:values].is_a?(ActionController::Parameters)
  end

  def submitted_values
    params.fetch(:values, ActionController::Parameters.new).permit(*SUBMITTED_KEYS).to_h
  end
end
