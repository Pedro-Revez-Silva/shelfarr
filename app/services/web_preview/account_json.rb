# frozen_string_literal: true

module WebPreview
  class AccountJson
    SCOPE_LABELS = {
      "search:read" => "Search",
      "requests:read" => "Read requests",
      "requests:write" => "Create and cancel requests",
      "library:read" => "Read and download the library",
      "progress:write" => "Save reading and listening progress",
      "requests:admin" => "Manage everyone's requests",
      "users:write" => "Create users"
    }.freeze

    def initialize(user, routes:)
      @user = user
      @routes = routes
    end

    def profile
      { id: @user.id.to_s, username: @user.username, name: @user.name, settings: settings }
    end

    def token(api_token)
      {
        id: api_token.id.to_s,
        name: api_token.name.to_s,
        prefix: api_token.token_prefix.to_s,
        scopes: api_token.scope_list,
        app: api_token.issued_via == APIToken::CONSUMER_DEVICE,
        state: token_state(api_token),
        created_at: api_token.created_at.iso8601(3),
        last_used_at: api_token.last_used_at&.iso8601(3),
        expires_at: api_token.expires_at&.iso8601(3)
      }
    end

    private

    def settings
      {
        admin: @user.admin?,
        member_since: @user.created_at.iso8601(3),
        requests: { total: @user.requests.count, completed: @user.requests.completed.count, pending: @user.requests.pending.count },
        two_factor: { enabled: @user.otp_enabled? },
        oidc: oidc,
        api_tokens: @user.api_tokens.order(created_at: :desc, id: :desc).map { |api_token| token(api_token) },
        token_scopes: allowed_scopes.map { |scope| { scope: scope, label: SCOPE_LABELS.fetch(scope, scope) } },
        links: links,
        server: { release: Shelfarr::ReleaseChannel.current.label, beta: Shelfarr::ReleaseChannel.current.beta?, series: Shelfarr::ReleaseChannel.current.series.to_s }
      }
    end

    def allowed_scopes
      @user.admin? ? APIToken::AVAILABLE_SCOPES : APIToken::SELF_SERVICE_SCOPES
    end

    def token_state(api_token)
      return "revoked" if api_token.revoked?
      return "expired" if api_token.expires_at.present? && api_token.expires_at <= Time.current

      "active"
    end

    def oidc
      configured = SettingsService.oidc_configured?
      {
        configured: configured,
        provider: configured ? SettingsService.get(:oidc_provider_name, default: "SSO").to_s : nil,
        linked: configured && @user.oidc_user?,
        link_page: configured && !@user.oidc_user? ? @routes.profile_path : nil,
        password_required: !SettingsService.auth_disabled?
      }
    end

    def links
      value = { kobo_readers: @routes.kobo_devices_path, kobo_accounts: @routes.kobo_accounts_path, hardcover: @routes.profile_path(anchor: "hardcover"),
        sign_out: @routes.session_path, phone_app: @routes.consumer_connect_path, reading_library: @routes.consumer_library_path }
      value[:kobo_shared] = @routes.kobo_shared_libraries_path if @user.received_kobo_account_shares.effective.exists?
      android = @routes.helpers.android_app_page_path
      value[:android_app] = android if android
      value[:admin] = @routes.admin_root_path if @user.admin?
      value
    end
  end
end
