# frozen_string_literal: true

class CollectionsController < ApplicationController
  PER_PAGE = 24
  BOOK_TYPES = %w[ebook audiobook].freeze

  before_action :set_collection, only: [ :show, :request_books ]
  rescue_from ActiveRecord::RecordNotFound, with: :record_not_found

  def index
    load_collections
  end

  def create
    @source_id = params[:source_id]
    unless @source_id.is_a?(String) && @source_id.match?(/\A[1-9]\d{0,9}\z/) && @source_id.to_i <= 2_147_483_647
      @errors = [ "Enter a valid Hardcover series ID." ]
      load_collections
      return render :index, status: :unprocessable_entity
    end

    collection = BookCollectionImportService.call(source_id: @source_id)
    redirect_to collection_path(collection), status: :see_other
  rescue BookCollectionImportService::Error => error
    @errors = [ error.message ]
    load_collections
    render :index, status: :unprocessable_entity
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    collection_save_conflict
  rescue ActiveRecord::StatementInvalid => error
    raise unless error.cause.is_a?(SQLite3::BusyException)

    collection_save_conflict
  end

  def show
    load_collection
    @selected_book_types = [ "ebook" ]
    @whole_series = true
    @selected_membership_ids = @memberships.reject(&:ambiguous?).map { |membership| membership.id.to_s }
  end

  def request_books
    load_collection
    @selected_book_types = scalar_array(params[:book_types])
    @selected_membership_ids = scalar_array(params[:membership_ids])
    @whole_series = params[:whole_series] == "1"
    raise ActionController::BadRequest if params[:language].present? && !params[:language].is_a?(String)

    @language = params[:language] if params[:language].is_a?(String)

    @errors = []
    @errors << "Select ebooks, audiobooks, or both." if @selected_book_types.empty?
    @errors << "Select only ebooks and audiobooks." if (@selected_book_types - BOOK_TYPES).any?
    @errors << "Choose the whole series or individual books." unless params[:whole_series].in?(%w[0 1])
    return render :show, status: :unprocessable_entity if @errors.any?

    result = BookCollectionRequestService.call(
      collection: @collection,
      user: Current.user,
      book_types: @selected_book_types,
      whole_series: @whole_series,
      membership_ids: @selected_membership_ids,
      language: @language
    )

    @errors = result.errors
    message = "#{result.created_requests.size} #{'request'.pluralize(result.created_requests.size)} created."
    message += " #{result.skipped.size} skipped." if result.skipped.any?
    if @errors.any?
      flash.now[:notice] = message if result.created_requests.any? || result.skipped.any?
      load_collection
      render :show, status: :unprocessable_entity
    else
      redirect_to collection_path(@collection), notice: message, status: :see_other
    end
  end

  private

  def set_collection
    @collection = BookCollection.find(params[:id])
  end

  def collection_save_conflict
    @errors = [ "The collection could not be saved right now. Please try again." ]
    load_collections
    render :index, status: :conflict
  end

  def load_collections
    @total = BookCollection.count
    @total_pages = [ (@total.to_f / PER_PAGE).ceil, 1 ].max
    @page = params[:page].to_i.clamp(1, @total_pages)
    @collections = BookCollection.order(:title, :id).offset((@page - 1) * PER_PAGE).limit(PER_PAGE)
    @membership_counts = CollectionMembership.where(book_collection_id: @collections.map(&:id)).group(:book_collection_id).count
  end

  def load_collection
    @memberships = @collection.collection_memberships.order(:sort_order, :id)
      .includes(book_work: { books: :requests }).to_a
    @availability = @memberships.to_h do |membership|
      [ membership.id, BOOK_TYPES.index_with { |book_type| availability_for(membership.book_work, book_type) } ]
    end
    @language ||= SettingsService.get(:default_language)
    @enabled_languages = BookCollectionRequestService.enabled_languages.filter_map do |code|
      info = ReleaseParserService.language_info(code)
      [ info[:name], code ] if info
    end.sort_by(&:first)
  end

  def availability_for(work, book_type)
    books = work.books.select { |book| book.book_type == book_type }
    return "In library" if books.any?(&:acquired?)
    return "Processing" if books.any?(&:acquisition_reserved?)

    requests = books.flat_map(&:requests)
    return "Downloading" if requests.any?(&:downloading?)
    return "Processing" if requests.any?(&:processing?)
    return "Requested" if requests.any?(&:open?)

    "Missing"
  end

  def scalar_array(value)
    return [] if value.nil?
    raise ActionController::BadRequest unless value.is_a?(Array) && value.all? { |item| item.is_a?(String) }

    value.uniq
  end

  def record_not_found
    redirect_to collections_path, alert: "Collection not found."
  end
end
