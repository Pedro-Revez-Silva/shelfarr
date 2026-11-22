# frozen_string_literal: true

class WebPreview::BooksController < WebPreview::APIController
  include ConsumerWebPublication

  CREATION_LOCK = Mutex.new
  Outcome = Data.define(:created, :results)

  def show
    render json: { account: web_preview_account_id, book: book_representation(book_page) }
  end

  def create_request
    outcome = CREATION_LOCK.synchronize do
      API::Consumer::V1::RequestsController.creation_lock(Current.user.id).synchronize { request_chosen_formats(book_page) }
    end
    return render_error("invalid_request", :unprocessable_entity) if outcome == :invalid
    return web_preview_signed_out unless Session.exists?(Current.session.id)
    return web_preview_not_found unless WebPreview::Access.current.allows?(Current.session.user.reload)
    return render_error("request_rejected", :unprocessable_entity, message: outcome) if outcome.is_a?(String)

    render json: { account: web_preview_account_id, outcome: outcome.created ? :created : :existing, results: outcome.results, book: book_representation(book_page) },
      status: outcome.created ? :created : :ok
  end

  private

  def request_chosen_formats(page)
    choice = request_options(page).choice(params)
    choice ? request_formats(page, choice) : :invalid
  end

  def request_options(page)
    WebPreview::RequestOptions.new(content_kind: ContentKinds.resolve(nil, source_work_ids: page.work_ids))
  end

  def request_formats(page, choice)
    wanted = choice.book_types.select { |book_type| page.requestable?(book_type) }
    return Outcome.new(created: false, results: choice.book_types.map { |book_type| { book_type: book_type, outcome: "existing" } }) if wanted.empty?
    return "This book's details could not be loaded, so it cannot be requested yet. Try again later." if page.metadata[:title].blank?

    result = RequestCreationService.call(
      user: Current.user,
      work_id: page.work_ids.first,
      source_work_ids: page.work_ids.drop(1),
      book_types: wanted,
      metadata_attrs: page.metadata.slice(:title, :author, :cover_url, :year, :description).merge(content_kind: ContentKinds::BOOK),
      language: choice.language,
      notes: choice.notes,
      origin: { created_via: "web" }
    )
    created = result.created_requests.map { |request| request.book.book_type }
    return rejection(result.errors.first) if created.empty?

    Outcome.new(created: true, results: choice.book_types.map { |book_type| format_result(book_type, wanted, created, result.errors) })
  end

  def format_result(book_type, wanted, created, errors)
    return { book_type: book_type, outcome: "created" } if created.include?(book_type)
    return { book_type: book_type, outcome: "existing" } unless wanted.include?(book_type)

    label = RequestOptionPolicy.book_type_label(book_type)
    { book_type: book_type, outcome: "rejected", message: rejection(errors.find { |error| error.to_s.include?(" #{label}: ") } || errors.first) }
  end

  def rejection(error)
    error.to_s.first(300).presence || "The request could not be made."
  end

  def book_representation(page)
    page.representation.merge(request_options: request_options(page).representation)
  end

  def book_page
    work_id = WebPreview::BookPage.work_id(params[:source], params[:source_id])
    raise ActiveRecord::RecordNotFound unless work_id

    details = WebPreview::BookHandoff.fetch(user: Current.user, token: params[:metadata], work_id: work_id)
    WebPreview::BookPage.new(user: Current.user, work_id: work_id, links: details[:links], details: details, publication: ->(book) { publication_summary(book) })
  end

  def publication_summary(book)
    representation = Consumer::Publication.new(book, user: Current.user, routes: self, reader_formats: web_reader_formats).representation
    WebPreview::PublicationJson.new(book: book, representation: representation, reader_path: consumer_publication_path(book),
      progress_label: helpers.consumer_progress_label(representation), format_label: helpers.consumer_format_label(book, representation),
      cover_style: helpers.consumer_cover_style(book)).summary
  end
end
