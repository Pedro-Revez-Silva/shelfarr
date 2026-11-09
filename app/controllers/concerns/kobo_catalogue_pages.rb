# frozen_string_literal: true

# Pagination and the "can be sent" filter shared by the owner's and a
# recipient's view of one Kobo account catalogue.
module KoboCataloguePages
  PAGE_SIZE = 50

  private

  def load_catalogue(account)
    @filter = params[:filter] == "sendable" ? "sendable" : "all"
    scope = account.kobo_account_books
    scope = scope.sendable if @filter == "sendable"
    @page = [ params[:page].to_i, 1 ].max
    @books = scope.order(:title, :id).offset((@page - 1) * PAGE_SIZE).limit(PAGE_SIZE + 1).to_a
    @more = @books.size > PAGE_SIZE
    @books = @books.first(PAGE_SIZE)
    @count = account.kobo_account_books.count
    @sendable_count = account.kobo_account_books.sendable.count
  end

  def prevent_caching
    response.headers["Cache-Control"] = "private, no-store"
  end
end
