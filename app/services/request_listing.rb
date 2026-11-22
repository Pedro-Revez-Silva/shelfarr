# frozen_string_literal: true

class RequestListing
  PER_PAGE = 25
  MAX_QUERY = 200
  MAX_PAGE = 1_000_000
  FOLD_FUNCTION = "shelfarr_request_search_lower"

  attr_reader :query, :page, :total_count, :total_pages

  def self.fold(value)
    value.to_s.unicode_normalize(:nfc).downcase
  end

  def initialize(user:, status: nil, attention: nil, query: nil, page: nil, includes: [ :book, :search_results ])
    @user = user
    @status = status.presence
    @attention = attention == "true"
    @query = query.to_s.strip.first(MAX_QUERY)
    @includes = user.admin? ? [ *includes, :user ] : includes
    paginate(page)
  end

  def everyone?
    @user.admin?
  end

  def requests
    @requests ||= filtered.order(created_at: :desc).limit(PER_PAGE).offset((page - 1) * PER_PAGE)
  end

  def attention_count
    @attention_count ||= base.needs_attention.count
  end

  def active_count
    @active_count ||= base.active.where(attention_needed: false).count
  end

  private

  def base
    everyone? ? Request : Request.for_user(@user)
  end

  def filtered
    @filtered ||= begin
      scope = base.includes(*@includes)
      scope = @status == "active" ? scope.active.where(attention_needed: false) : scope.where(status: @status) if @status
      scope = scope.needs_attention if @attention
      @query.present? ? matching(scope) : scope
    end
  end

  def matching(scope)
    register_fold_function!
    like = "%#{ActiveRecord::Base.sanitize_sql_like(self.class.fold(@query))}%"
    scope.joins(:book).where("#{FOLD_FUNCTION}(books.title) LIKE :q ESCAPE '\\' OR #{FOLD_FUNCTION}(books.author) LIKE :q ESCAPE '\\'", q: like)
  end

  def register_fold_function!
    database = Request.connection.raw_connection
    return unless database.respond_to?(:create_function)

    database.create_function(FOLD_FUNCTION, 1) { |function, value| function.result = self.class.fold(value) }
  end

  def paginate(requested)
    @total_count = filtered.count
    @total_pages = [ (@total_count.to_f / PER_PAGE).ceil, 1 ].max
    @page = requested.to_i.clamp(1, MAX_PAGE).clamp(1, @total_pages)
  end
end
