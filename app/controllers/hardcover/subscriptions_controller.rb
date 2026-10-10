# frozen_string_literal: true

module Hardcover
  # Previewing, following, and managing Hardcover lists, Want to Read
  # shelves, and authors. Every lookup is scoped to the signed-in user.
  class SubscriptionsController < ApplicationController
    PER_PAGE = 48
    MANUAL_REFRESH_COOLDOWN = 5.minutes
    MAX_SELECTION = 1_000
    FILTERS = {
      "all" => nil,
      "new" => %w[pending],
      "upcoming" => %w[upcoming],
      "requested" => %w[queued requested],
      "attention" => %w[failed],
      "not_requested" => %w[known ignored]
    }.freeze

    before_action :require_hardcover
    before_action :set_subscription, except: [ :index, :create ]

    def index
      @connection = Current.user.hardcover_connection
      @subscriptions = Current.user.hardcover_subscriptions.order(Arel.sql("status = 'draft'"), :title).to_a
      @item_counts = HardcoverSubscriptionItem.where(hardcover_subscription_id: @subscriptions.map(&:id)).group(:hardcover_subscription_id, :state).count
      load_account_lists if @connection&.usable?
    end

    def create
      kind = params[:kind].to_s
      unless HardcoverSubscription::KINDS.include?(kind)
        redirect_to hardcover_subscriptions_path, alert: "Choose a list, Want to Read shelf, or author to follow."
        return
      end

      attrs = resolve_target(kind)
      return if performed?

      subscription = Current.user.hardcover_subscriptions.find_or_initialize_by(
        target_key: HardcoverSubscription.target_key_for(kind, attrs[:hardcover_target_id])
      )
      if subscription.persisted? && !subscription.draft?
        redirect_to hardcover_subscription_path(subscription), notice: "You already follow #{subscription.title}."
        return
      end

      subscription.assign_attributes(attrs.merge(kind: kind, status: "draft", snapshot_state: "pending", last_error: nil))
      subscription.book_types = default_book_types if subscription.book_types.empty?
      subscription.save!
      HardcoverSubscriptionSyncJob.perform_later(subscription.id, mode: "snapshot")
      redirect_to hardcover_subscription_path(subscription)
    rescue ActiveRecord::RecordInvalid => e
      redirect_to hardcover_subscriptions_path, alert: e.record.errors.full_messages.to_sentence
    end

    def show
      @filter = FILTERS.key?(params[:filter]) ? params[:filter] : (@subscription.draft? ? "all" : default_filter)
      scope = @subscription.items
      scope = scope.where(state: FILTERS[@filter]) if FILTERS[@filter]
      @state_counts = @subscription.items.group(:state).count
      @total_items = scope.count
      @page_count = [ (@total_items.to_f / PER_PAGE).ceil, 1 ].max
      @page = params[:page].to_i.clamp(1, @page_count)
      @items = scope.order(item_order).limit(PER_PAGE).offset((@page - 1) * PER_PAGE).to_a
      @existing_books_lookup = Book.preload_by_work_ids(@items.map(&:work_id))
      @available_book_types = RequestOptionPolicy.book_types_for(ContentKinds::BOOK)
    end

    # Confirms a draft (baseline + optional automatic sync) or changes the
    # settings of a followed subscription.
    def update
      book_types = permitted_book_types
      if book_types.empty?
        redirect_to hardcover_subscription_path(@subscription), alert: "Choose at least one format to request."
        return
      end

      automatic = ActiveModel::Type::Boolean.new.cast(params[:automatic]) == true
      if @subscription.draft?
        confirm_draft(book_types, automatic)
      else
        @subscription.update!(book_types: book_types, automatic: automatic)
        redirect_to hardcover_subscription_path(@subscription), notice: "Settings saved."
      end
    end

    # Queues the selected books with the chosen formats.
    def request_items
      book_types = permitted_book_types
      items = selected_items
      if book_types.empty? || items.empty?
        redirect_to hardcover_subscription_path(@subscription, filter: params[:filter]), alert: "Select at least one book and one format."
        return
      end
      if @subscription.draft?
        redirect_to hardcover_subscription_path(@subscription), alert: "Confirm the preview first."
        return
      end

      queued = queue_items(items, book_types)
      HardcoverImportJob.perform_later if queued.positive?
      redirect_to hardcover_subscription_path(@subscription, filter: "requested"),
        notice: queued.positive? ? "Queued #{helpers.pluralize(queued, 'book')} for request." : "Nothing to request."
    end

    def refresh
      if @subscription.paused?
        redirect_to hardcover_subscription_path(@subscription), alert: "Resume this subscription first."
        return
      end
      if @subscription.snapshot_loading?
        redirect_to hardcover_subscription_path(@subscription), notice: "Already loading from Hardcover."
        return
      end
      if @subscription.last_synced_at.present? && @subscription.last_synced_at > MANUAL_REFRESH_COOLDOWN.ago
        redirect_to hardcover_subscription_path(@subscription), notice: "Checked recently. Try again in a few minutes."
        return
      end

      mode = @subscription.draft? || @subscription.author? ? "snapshot" : "manual"
      @subscription.update!(snapshot_state: "pending") if mode == "snapshot"
      HardcoverSubscriptionSyncJob.perform_later(@subscription.id, mode: mode)
      redirect_to hardcover_subscription_path(@subscription), notice: "Checking Hardcover for changes."
    end

    def pause
      @subscription.pause!("Paused by you.") unless @subscription.draft?
      redirect_to hardcover_subscription_path(@subscription), notice: "Paused. Nothing new will be requested until you resume.", status: :see_other
    end

    def resume
      if @subscription.requires_connection? && !Current.user.hardcover_connection&.usable?
        redirect_to profile_path, alert: "Reconnect your Hardcover account first."
        return
      end

      @subscription.resume! if @subscription.paused?
      redirect_to hardcover_subscription_path(@subscription), notice: "Resumed.", status: :see_other
    end

    def destroy
      title = @subscription.title
      @subscription.destroy!
      redirect_to hardcover_subscriptions_path, notice: "Stopped following #{title}. Existing requests were kept.", status: :see_other
    end

    def update_item
      item = @subscription.items.find(params[:item_id])
      case params[:item_action]
      when "ignore"
        item.update!(state: "ignored") if item.state.in?(%w[known pending failed upcoming])
      when "restore"
        item.update!(state: item.unreleased? ? "upcoming" : "pending") if item.ignored?
      when "retry"
        if item.failed? && !@subscription.draft?
          item.update!(state: "queued", next_attempt_at: nil, claim_token: nil, claimed_at: nil, attempts: 0)
          HardcoverImportJob.perform_later
        end
      else
        redirect_to hardcover_subscription_path(@subscription), alert: "Unknown action."
        return
      end
      redirect_to hardcover_subscription_path(@subscription, filter: params[:filter], page: params[:page]), status: :see_other
    end

    private

    def require_hardcover
      return if HardcoverIntegration.enabled?

      redirect_to root_path, alert: "Hardcover is disabled on this Shelfarr instance."
    end

    def set_subscription
      @subscription = Current.user.hardcover_subscriptions.find_by(id: params[:id])
      return if @subscription

      redirect_to hardcover_subscriptions_path, alert: "That subscription was not found."
    end

    def load_account_lists
      @account_lists = Rails.cache.fetch("hardcover:account-lists:v1:#{@connection.id}:#{@connection.hardcover_user_id}", expires_in: 10.minutes) do
        Credentials.with_connection(@connection) do |credential|
          API.user_lists(user_id: @connection.hardcover_user_id, credential: credential)
        end
      end
    rescue HardcoverClient::Error, Credentials::Unavailable => e
      @account_lists = []
      @account_lists_error = e.is_a?(HardcoverClient::RateLimitError) ? "Hardcover's rate limit was reached; your lists will load again shortly." : "Your Hardcover lists could not be loaded right now."
    end

    def resolve_target(kind)
      case kind
      when "want_to_read"
        connection = Current.user.hardcover_connection
        unless connection&.usable?
          redirect_to profile_path, alert: "Connect your Hardcover account to use your Want to Read shelf."
          return {}
        end
        { title: "Want to Read", hardcover_target_id: nil, owner_username: connection.hardcover_username, slug: nil }
      when "list"
        list = with_reader(kind) { |credential| API.list(target_id_param, credential: credential) }
        return {} if performed?

        { title: list.name, hardcover_target_id: list.id, slug: list.slug, description: list.description, owner_username: list.owner_username }
      when "author"
        author = with_reader(kind) do |credential|
          found = API.author(target_id_param, credential: credential)
          found.canonical_id.present? ? API.author(found.canonical_id, credential: credential) : found
        end
        return {} if performed?

        { title: author.name, hardcover_target_id: author.id, slug: author.slug, description: author.bio, image_url: author.image_url }
      end
    end

    def target_id_param
      id = Integer(params[:hardcover_target_id].to_s, exception: false)
      raise HardcoverClient::NotFoundError, "Invalid Hardcover identifier" unless id&.positive?

      id
    end

    def with_reader(kind)
      connection = Current.user.hardcover_connection
      if kind == "list" && connection&.usable?
        Credentials.with_connection(connection) { |credential| yield credential }
      else
        Credentials.with_catalog(user: Current.user) { |credential| yield credential }
      end
    rescue HardcoverClient::NotFoundError
      redirect_to hardcover_subscriptions_path, alert: "Hardcover could not find that #{kind}, or it is private."
      nil
    rescue HardcoverClient::RateLimitError
      redirect_to hardcover_subscriptions_path, alert: "Hardcover's rate limit was reached. Try again in a few minutes."
      nil
    rescue HardcoverClient::Error, Credentials::Unavailable => e
      redirect_to hardcover_subscriptions_path, alert: "Could not load that #{kind} from Hardcover: #{e.message}"
      nil
    end

    def confirm_draft(book_types, automatic)
      unless @subscription.snapshot_ready?
        redirect_to hardcover_subscription_path(@subscription), alert: "Wait for the preview to finish loading."
        return
      end

      queued = 0
      HardcoverSubscription.transaction do
        baseline = @subscription.snapshot_completed_at || Time.current
        @subscription.update!(
          status: "active",
          book_types: book_types,
          automatic: automatic,
          baseline_established_at: baseline,
          sync_cursor_at: baseline,
          next_sync_at: Time.current + @subscription.sync_interval,
          consecutive_failures: 0,
          last_error: nil
        )
        queued = queue_items(selected_items, book_types)
      end
      HardcoverImportJob.perform_later if queued.positive?

      message = "Following #{@subscription.title}."
      message += " Queued #{helpers.pluralize(queued, 'book')} for request." if queued.positive?
      message += automatic ? " New additions will be requested automatically." : " New additions will be listed here for you to review."
      redirect_to hardcover_subscription_path(@subscription), notice: message
    end

    # Released books are queued now; selected upcoming books are marked so
    # they are requested once they come out.
    def queue_items(items, book_types)
      queued = 0
      items.each do |item|
        if item.upcoming?
          item.update!(wanted: true, book_types: book_types)
        elsif item.requestable?
          item.queue_for_import!(book_types)
          queued += 1
        end
      end
      queued
    end

    # "Select all" is an explicit opt-in to request every released book the
    # user has not requested yet; otherwise only the ticked items count.
    def selected_items
      if params[:select_all] == "1"
        return @subscription.items.where(state: HardcoverSubscriptionItem::REQUESTABLE_STATES - %w[ignored])
          .order(:id).limit(MAX_SELECTION).to_a.select(&:requestable?)
      end

      ids = Array(params[:item_ids]).filter_map { |value| Integer(value.to_s, exception: false) }.uniq.first(MAX_SELECTION)
      return [] if ids.empty?

      @subscription.items.where(id: ids).to_a
    end

    # Formats are validated on the server; an unsupported value rejects the
    # whole submission instead of being silently dropped.
    def permitted_book_types
      allowed = RequestOptionPolicy.book_types_for(ContentKinds::BOOK)
      requested = Array(params[:book_types]).map(&:to_s).compact_blank.uniq
      return [] if (requested - allowed).any?

      requested
    end

    def default_book_types
      [ "ebook" ]
    end

    def default_filter
      if @subscription.items.pending.exists? then "new"
      elsif @subscription.items.failed.exists? then "attention"
      else "all"
      end
    end

    def item_order
      if @subscription.author?
        Arel.sql("release_date IS NULL, release_date DESC, title ASC")
      elsif @subscription.list?
        Arel.sql("position IS NULL, position ASC, entry_added_at DESC, id ASC")
      else
        Arel.sql("entry_added_at IS NULL, entry_added_at DESC, id ASC")
      end
    end
  end
end
