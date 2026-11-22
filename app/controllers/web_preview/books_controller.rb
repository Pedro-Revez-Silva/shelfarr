# frozen_string_literal: true

class WebPreview::BooksController < WebPreview::APIController
  include ConsumerWebPublication

  REQUESTED_TYPE = "ebook"

  def show
    render json: { account: web_preview_account_id, book: book_page.representation }
  end

  def create_request
    page = book_page
    outcome = API::Consumer::V1::RequestsController.creation_lock(Current.user.id).synchronize { request_ebook(page) }
    return render_error("request_rejected", :unprocessable_entity, message: outcome) if outcome.is_a?(String)

    render json: { account: web_preview_account_id, outcome: outcome, book: book_page.representation }, status: outcome == :created ? :created : :ok
  end

  private

  def request_ebook(page)
    return :existing if duplicate?(page)
    return "This book's details could not be loaded, so it cannot be requested yet. Try again later." if page.metadata[:title].blank?

    result = RequestCreationService.call(
      user: Current.user,
      work_id: page.work_ids.first,
      source_work_ids: page.work_ids.drop(1),
      book_types: [ REQUESTED_TYPE ],
      metadata_attrs: page.metadata.slice(:title, :author, :cover_url, :year, :description).merge(content_kind: ContentKinds::BOOK),
      origin: { created_via: "web" }
    )
    return :created if result.created_requests.any?
    return :existing if duplicate?(page)

    result.errors.first.to_s.first(300).presence || "The request could not be made."
  end

  def duplicate?(page)
    DuplicateDetectionService.check(work_id: page.work_ids.first, source_work_ids: page.work_ids.drop(1), book_type: REQUESTED_TYPE).block?
  end

  def book_page
    work_id = WebPreview::BookPage.work_id(params[:source], params[:source_id])
    raise ActiveRecord::RecordNotFound unless work_id

    WebPreview::BookPage.new(
      user: Current.user,
      work_id: work_id,
      also: WebPreview::BookPage.also(params[:also], except: work_id),
      handoff: RequestMetadataHandoff.fetch(user: Current.user, token: params[:metadata]),
      publication: ->(book) { publication_summary(book) }
    )
  end

  def publication_summary(book)
    representation = Consumer::Publication.new(book, user: Current.user, routes: self, reader_formats: web_reader_formats).representation
    WebPreview::PublicationJson.new(book: book, representation: representation, reader_path: consumer_publication_path(book),
      progress_label: helpers.consumer_progress_label(representation), format_label: helpers.consumer_format_label(book, representation),
      cover_style: helpers.consumer_cover_style(book)).summary
  end
end
