# frozen_string_literal: true

class WebPreview::Admin::UsersController < WebPreview::Admin::BaseController
  class Refused < StandardError
    attr_reader :outcome

    def initialize(outcome)
      @outcome = outcome
      super(outcome.to_s)
    end
  end

  ROLES = { "member" => "user", "administrator" => "admin" }.freeze
  PASSWORD_FIELDS = %w[password password_confirmation].freeze
  OWN_ACCOUNT = {
    password: "Change your own password in Account, under Sign-in and security.",
    remove: "You cannot remove your own account."
  }.freeze

  before_action :set_user, only: %i[show update password remove]
  rescue_from ActionDispatch::Http::Parameters::ParseError, with: -> { render_error("invalid_request", :bad_request) }

  def index
    users = User.active.order(created_at: :desc, id: :desc).to_a
    render json: { account: web_preview_account_id, users: users.map { |user| row(user) } }
  end

  def show
    render_user(@user)
  end

  def create
    values = body_values(%w[name username role] + PASSWORD_FIELDS)
    role = ROLES[values&.dig("role")]
    return render_error("invalid_request", :bad_request) unless role

    user = User.new(values.slice("name", "username", *PASSWORD_FIELDS).merge(role: role))
    outcome = User.transaction do
      next :forbidden unless acting_administrator?

      acceptable?(user, values["password"]) && user.save ? :saved : :rejected
    end
    @user = user
    answer_write(outcome, status: :created)
  end

  def update
    values = body_values(%w[name username role version])
    role = ROLES[values&.dig("role")]
    return render_error("invalid_request", :bad_request) unless role

    administrators_seen = request.request_parameters["administrators"]
    return render_error("invalid_request", :bad_request) if demoting_self?(role) && !administrators_seen.is_a?(Integer)

    outcome = @user.with_lock do
      next :forbidden unless acting_administrator?
      next :removed if @user.deleted?
      next :changed unless values["version"] == version(@user)
      next :changed if demoting_self?(role) && administrators_seen != User.active.admin.count

      @user.update(name: values["name"], username: values["username"], role: role) ? :saved : :rejected
    end
    answer_write(outcome)
  end

  def password
    values = body_values(PASSWORD_FIELDS)
    return render_error("invalid_request", :bad_request) unless values
    return render_own_account(:password) if @user == Current.user

    if values["password"].blank?
      @user.errors.add(:password, :blank)
      return render_rejection(@user)
    end
    outcome = @user.with_lock do
      next :forbidden unless acting_administrator?
      next :removed if @user.deleted?

      @user.update(values) ? :saved : :rejected
    end
    answer_write(outcome)
  end

  def remove
    values = body_values(%w[version])
    return render_error("invalid_request", :bad_request) unless values
    return render_own_account(:remove) if @user == Current.user

    @user.soft_delete! { confirm_removal(values["version"]) }
    render json: { account: web_preview_account_id, removed: @user.id.to_s }
  rescue Refused => refusal
    answer_write(refusal.outcome)
  end

  private

  def set_user
    @user = User.active.find_by(id: params[:id])
    render_missing unless @user
  end

  def body_values(fields)
    body = request.request_parameters
    values = fields.index_with { |field| body[field] }
    values if values.values.all?(String)
  end

  def demoting_self?(role)
    @user == Current.user && @user.admin? && role == "user"
  end

  def acting_administrator?
    User.active.admin.exists?(id: Current.user.id)
  end

  def acceptable?(user, password)
    user.valid?
    user.errors.add(:password, :blank) if password.blank? && !user.errors.added?(:password, :blank)
    user.errors.empty?
  end

  def confirm_removal(expected_version)
    @user.lock!
    raise Refused, :forbidden unless acting_administrator?
    raise Refused, :removed if @user.deleted?
    raise Refused, :changed unless expected_version == version(@user)
  end

  def answer_write(outcome, status: :ok)
    case outcome
    when :saved then render_user(@user, status: status)
    when :rejected then render_rejection(@user)
    when :removed then render_missing
    when :forbidden then render_error("not_found", :not_found)
    else render json: { account: web_preview_account_id, error: "user_changed", **user_json(@user.reload) }, status: :conflict
    end
  end

  def render_user(user, status: :ok)
    render json: { account: web_preview_account_id, **user_json(user) }, status: status
  end

  def user_json(user)
    { user: row(user).merge(requests: user.requests.count, version: version(user)), administrators: User.active.admin.count }
  end

  def row(user)
    {
      id: user.id.to_s,
      name: user.name,
      username: user.username,
      role: ROLES.key(user.role),
      self: user == Current.user,
      created_at: user.created_at.iso8601(3)
    }
  end

  def version(user)
    Digest::SHA256.hexdigest([ user.id, user.name, user.username, user.role ].to_json)[0, 24]
  end

  def render_rejection(user)
    render json: { account: web_preview_account_id, error: "invalid_user", errors: user.errors.to_hash }, status: :unprocessable_entity
  end

  def render_own_account(action)
    render json: { account: web_preview_account_id, error: "own_account", message: OWN_ACCOUNT.fetch(action) }, status: :unprocessable_entity
  end

  def render_missing
    render_error("user_not_found", :not_found)
  end
end
