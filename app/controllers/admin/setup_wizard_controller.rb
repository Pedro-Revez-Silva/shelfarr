# frozen_string_literal: true

module Admin
  class SetupWizardController < BaseController
    def show
      @step = SetupWizard.normalize_step(params[:step])
      prepare_step
    end

    def update
      @step = SetupWizard.normalize_step(params[:step])
      result = SetupWizard.save(@step, wizard_params)
      if result.success?
        redirect_after_save(result)
      else
        @error = result.error
        prepare_step
        render :show, status: :unprocessable_entity
      end
    end

    def skip
      following = SetupWizard.skip(params[:step], exit_setup: params[:exit].present?)
      if following
        redirect_to admin_setup_wizard_path(step: following)
      else
        redirect_to root_path, notice: "Setup skipped. You can run it again from Setup in the header."
      end
    end

    def restart
      SetupWizard.restart!
      redirect_to admin_setup_wizard_path
    end

    private

    def redirect_after_save(result)
      following = SetupWizard.step_after_save(@step, result)
      if result.stay?
        # Preselect libraries only right after connecting, so a saved "Not now" stays.
        redirect_to admin_setup_wizard_path(step: @step), notice: result.notice, flash: { suggest_libraries: true }
      elsif following.nil?
        redirect_to root_path, notice: "Setup complete."
      else
        options = { notice: result.notice }
        options[:alert] = result.alert if result.alert.present?
        redirect_to admin_setup_wizard_path(step: following), **options
      end
    end

    def prepare_step
      form = SetupWizard::Form.new(step: @step, submitted: params[:wizard], suggest_libraries: flash[:suggest_libraries])
      SetupWizard::Form::ATTRIBUTES.each { |name| instance_variable_set(:"@#{name}", form.public_send(name)) }
    end

    def wizard_params
      params.fetch(:wizard, ActionController::Parameters.new).permit(
        :url, :api_key, :username, :password, :category, :phase,
        :audiobook_output_path, :ebook_output_path, :download_local_path, :download_remote_path,
        :audiobook_library_id, :ebook_library_id,
        :immediate_search_enabled, :auto_select_enabled
      ).to_h
    end
  end
end
