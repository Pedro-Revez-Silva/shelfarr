# frozen_string_literal: true

class WebPreview::Admin::UsersController < WebPreview::Admin::BaseController
  ROLES = { "member" => "user", "administrator" => "admin" }.freeze
  PASSWORD_FIELDS = %w[password password_confirmation].freeze
  OWN_ACCOUNT = {
    password: "Change your own password in Account, under Sign-in and security.",
    remove: "You cannot remove your own account."
  }.freeze

  before_action :set_user, only: %i[show update password remove]

  def index
    users = User.active.order(created_at: :desc, id: :desc).to_a
    render json: { account: web_preview_account_id, users: users.map { |user| row(user) } }
  end

  def show
    render_user(@user)
  end

  def create
    values = text_values(%w[name username role] + PASSWORD_FIELDS)
    role = ROLES[values&.dig("role")]
    return render_error("invalid_request", :bad_request) unless role

    user = User.new(values.slice("name", "username", *PASSWORD_FIELDS).merge(role: role))
    return render_user(user, status: :created) if user.save

    render_rejection(user)
  end

  def update
    values = text_values(%w[name username role version])
    role = ROLES[values&.dig("role")]
    return render_error("invalid_request", :bad_request) unless role

    outcome = @user.with_lock do
      next :removed if @user.deleted?
      next :changed unless values["version"] == version(@user)

      @user.update(name: values["name"], username: values["username"], role: role) ? :saved : :rejected
    end
    answer_write(outcome)
  end

  def password
    values = text_values(PASSWORD_FIELDS)
    return render_error("invalid_request", :bad_request) unless values
    return render_own_account(:password) if @user == Current.user

    if values["password"].empty?
      @user.errors.add(:password, :blank)
      return render_rejection(@user)
    end
    return render_user(@user) if @user.update(values)

    render_rejection(@user)
  end

  def remove
    values = text_values(%w[version])
    return render_error("invalid_request", :bad_request) unless values
    return render_own_account(:remove) if @user == Current.user

    outcome = @user.with_lock do
      next :removed if @user.deleted?

      values["version"] == version(@user) ? :current : :changed
    end
    return answer_write(outcome) unless outcome == :current

    @user.soft_delete!
    render json: { account: web_preview_account_id, removed: @user.id.to_s }
  end

  private

  def set_user
    @user = User.active.find_by(id: params[:id])
    render_missing unless @user
  end

  def text_values(fields)
    values = fields.index_with { |field| params[field] }
    values if values.values.all?(String)
  end

  def answer_write(outcome)
    case outcome
    when :saved then render_user(@user)
    when :rejected then render_rejection(@user)
    when :removed then render_missing
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
