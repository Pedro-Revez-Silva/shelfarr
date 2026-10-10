# frozen_string_literal: true

# Browse Hardcover's public catalog: trending books, release windows, genres,
# public lists, and author catalogs. Requests go through the normal request
# form, so format choice and duplicate checks behave exactly like search.
class DiscoverController < ApplicationController
  before_action :require_hardcover
  before_action :set_page

  def index
    @view = Hardcover::Discovery::BOOK_VIEWS.include?(params[:view]) ? params[:view] : "trending"
    @period = Hardcover::Discovery::TRENDING_PERIODS.key?(params[:period]) ? params[:period] : "month"
    @genre = params[:genre].to_s.squish.first(60)
    with_catalog do |credential|
      result = Hardcover::Discovery.books(view: @view, credential: credential, page: @page, period: @period, genre: @genre)
      assign_books(result.entries, has_more: result.has_more)
    end
  end

  def lists
    @query = params[:q].to_s.squish.first(100)
    with_catalog do |credential|
      result = Hardcover::Discovery.lists(credential: credential, query: @query, page: @page)
      @lists = result.entries
      @has_more = result.has_more
    end
  end

  def list
    list_id = positive_id_param(:id)
    return if performed?

    with_catalog do |credential|
      view = Hardcover::Discovery.list(list_id, credential: credential, page: @page)
      @list = view.list
      assign_books(view.books, has_more: view.has_more)
    end
    @subscription = Current.user.hardcover_subscriptions.find_by(target_key: HardcoverSubscription.target_key_for("list", list_id))
  end

  def authors
    @query = params[:q].to_s.squish.first(100)
    with_catalog do |credential|
      result = Hardcover::Discovery.authors(@query, credential: credential, page: @page)
      @authors = result.entries
      @has_more = result.has_more
    end
  end

  def author
    author_id = positive_id_param(:id)
    return if performed?

    with_catalog do |credential|
      view = Hardcover::Discovery.author(author_id, credential: credential)
      if view.author.canonical_id.present? && view.author.canonical_id != author_id
        redirect_to discover_author_path(view.author.canonical_id)
        return
      end

      @author = view.author
      @excluded = view.excluded
      @truncated = view.truncated
      assign_books(view.books, has_more: false)
    end
    @subscription = Current.user.hardcover_subscriptions.find_by(target_key: HardcoverSubscription.target_key_for("author", author_id))
  end

  private

  def require_hardcover
    return if HardcoverIntegration.enabled?

    redirect_to search_path, alert: "Hardcover is disabled on this Shelfarr instance."
  end

  def set_page
    @page = params[:page].to_i.clamp(1, Hardcover::Discovery::MAX_PAGE)
  end

  def positive_id_param(name)
    id = Integer(params[name].to_s, exception: false)
    return id if id&.positive?

    redirect_to discover_path, alert: "That Hardcover link is not valid."
    nil
  end

  def with_catalog
    @catalog_available = Hardcover::Credentials.catalog_available?(user: Current.user)
    return unless @catalog_available

    Hardcover::Credentials.with_catalog(user: Current.user) { |credential| yield credential }
  rescue HardcoverClient::NotFoundError
    @error = "Hardcover could not find that page, or it is private."
  rescue HardcoverClient::RateLimitError => e
    @error = "Hardcover's rate limit was reached. Try again in #{helpers.distance_of_time_in_words(e.retry_after.to_i.seconds)}."
  rescue HardcoverClient::QueryTooLargeError
    @error = "Hardcover rejected this request as too large."
  rescue HardcoverClient::AuthenticationError
    @error = "Hardcover rejected the configured credentials. An administrator can check the token in Settings."
  rescue Hardcover::Credentials::Unavailable, HardcoverClient::Error => e
    Rails.logger.warn("[DiscoverController] Hardcover error: #{e.class}: #{e.message}")
    @error = "Hardcover could not be reached right now. Try again shortly."
  end

  def assign_books(entries, has_more:)
    @books = entries
    @has_more = has_more
    @existing_books_lookup = Book.preload_by_work_ids(entries.map(&:work_id))
  end
end
