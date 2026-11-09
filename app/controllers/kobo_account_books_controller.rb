# frozen_string_literal: true

# One title from a Kobo account catalogue, for its owner or a user it was
# shared with. Every action re-checks the grant; anyone else gets a 404, so a
# catalogue's existence is not revealed. Readers are always the viewer's own.
class KoboAccountBooksController < ApplicationController
  before_action :prevent_caching
  before_action :set_book

  def show
    @account = @book.kobo_account
    @file = @book.ready_file
    @cover = @file.present? && cover_image != :none
    @fetch = @book.active_fetch
    failure = @book.latest_failure
    @failure = failure if failure && (@file.nil? || failure.updated_at > @file.fetched_at)
    @devices = Current.user.kobo_devices.order(:name)
    @deliveries = KoboDelivery.where(kobo_account_book: @book, kobo_device: @devices).index_by(&:kobo_device_id)
  end

  def prepare
    Kobo::BookCache.request!(@book, Current.user)
    redirect_to kobo_account_book_path(@book), notice: "Preparing a private copy. This usually takes under a minute."
  rescue Kobo::BookCache::Failure => error
    redirect_to kobo_account_book_path(@book), alert: KoboAccountBookFile::ERROR_MESSAGES.fetch(error.code, "This copy can't be prepared.")
  end

  # The JSON contract of the kobo-account Stimulus poller.
  def status
    pending = @book.active_fetch.present?
    respond_to do |format|
      format.json { render json: { status: pending ? "pending" : "done", redirect_url: pending ? nil : kobo_account_book_path(@book) } }
      format.html { redirect_to kobo_account_book_path(@book) }
    end
  end

  def deliver
    device = Current.user.kobo_devices.find(params[:device_id])
    file = @book.ready_file
    unless @book.deliverable? && file
      return redirect_to(kobo_account_book_path(@book), alert: "Prepare a private copy of this book first.")
    end

    device.send_account_book!(file, share: @grant.share)
    redirect_to kobo_account_book_path(@book), notice: "Queued for #{device.name}. Sync that Kobo over Wi-Fi to download it."
  rescue KoboPublication::Unavailable => error
    redirect_to kobo_account_book_path(@book), alert: error.message
  end

  def cover
    image = cover_image
    return head(:not_found) if image == :none

    send_data image.first, type: image.last, disposition: "inline"
  end

  private

  # The embedded cover of the ready copy as [bytes, type], or :none.
  def cover_image
    file = Kobo::BookCache.open(@book.ready_file)
    KoboPublication.new(nil).cover(file) || :none
  rescue KoboPublication::Unavailable => error
    Rails.logger.info("[Kobo] No cover for a shared copy (#{error.class.name})")
    :none
  ensure
    file&.close unless file&.closed?
  end

  def set_book
    @book = Kobo::HouseholdAccess.visible_books(Current.user).find(params[:id])
    @grant = Kobo::HouseholdAccess.grant!(Current.user, @book.kobo_account)
  rescue Kobo::HouseholdAccess::Denied
    raise ActiveRecord::RecordNotFound
  end

  def prevent_caching
    response.headers["Cache-Control"] = "private, no-store"
  end
end
