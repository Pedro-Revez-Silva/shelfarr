# frozen_string_literal: true

module Admin
  class UploadsController < BaseController
    before_action :set_request_context, only: [ :new, :create ]
    before_action :set_upload, only: [ :show, :destroy, :retry, :match_and_retry ]

    def index
      @uploads = Upload.includes(:user, :book).recent
    end

    def new
      @upload = Upload.new(request: @request)
    end

    def create
      result = UploadCreator.call_many(
        user: Current.user,
        uploaded_files: upload_files,
        request: @request,
        skip_unsupported: folder_upload?
      )

      if result.success?
        flash[:notice] = result.notice if result.notice.present?
        flash[:alert] = result.alert if result.alert.present?
        redirect_to upload_success_location
      else
        redirect_to upload_failure_location, alert: result.alert
      end
    end

    def show
      prepare_manual_match
    end

    def match_and_retry
      attributes = manual_match_params
      outcome = administration.match_and_retry(attributes)
      case outcome.kind
      when :done then redirect_to admin_upload_path(@upload), notice: outcome.message
      when :invalid
        flash.now[:alert] = outcome.message
        prepare_manual_match
        render :show, status: :unprocessable_entity
      else redirect_to admin_upload_path(@upload), alert: outcome.message
      end
    end

    def destroy
      outcome = administration.destroy
      redirect_to admin_uploads_path, outcome.done? ? { notice: outcome.message } : { alert: outcome.message }
    end

    def retry
      outcome = administration.retry
      redirect_to admin_uploads_path, outcome.done? ? { notice: outcome.message } : { alert: outcome.message }
    end

    private

    def set_upload
      @upload = Upload.find(params[:id])
    end

    def administration
      UploadAdministration.new(@upload, user: Current.user)
    end

    def prepare_manual_match
      fields = params[:manual_book]
      choices = administration.match_choices(
        query: params.fetch(:q, @upload.parsed_title),
        page: params[:page],
        manual_book: fields.is_a?(ActionController::Parameters) ? fields.permit(:title, :author) : nil
      )
      return unless choices

      @match_query = choices.query
      @match_page = choices.page
      @manual_book = choices.manual_book
      @match_books = choices.books
    end

    def manual_match_params
      if params.key?(:book_id)
        { book_id: params.expect(:book_id) }
      else
        fields = params.expect(manual_book: [ :title, :author ])
        %i[title author].each do |field|
          if params[:manual_book].key?(field) && !fields.key?(field)
            raise ActionController::ParameterMissing, field
          end
        end
        fields.to_h.symbolize_keys
      end
    end

    def set_request_context
      return if params[:request_id].blank?

      @request = Request.includes(:book).find(params[:request_id])
      refusal = UploadRequestContext.refusal(@request, user: Current.user)
      redirect_to @request, alert: refusal.message if refusal
    end

    def upload_success_location
      @request || admin_uploads_path
    end

    def upload_failure_location
      @request ? new_admin_upload_path(request_id: @request.id) : new_admin_upload_path
    end

    def upload_files
      params[:files].presence || params[:file]
    end

    def folder_upload?
      params[:upload_mode] == "folder"
    end
  end
end
