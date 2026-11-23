# frozen_string_literal: true

module Hardcover
  class PersonalSignIn
    OAUTH_KEY = :hardcover_oauth
    DEVICE_KEY = :hardcover_device
    OUTCOME_KEY = :hardcover_outcome
    WARM_STATE_PREFIX = "preview-"
    API_KEY_LIMIT = 2_000
    OUTCOME_TTL = 10.minutes

    DevicePoll = Data.define(:status, :message, :connection)

    def self.api_key(raw)
      return unless raw.is_a?(String)

      key = raw.strip.sub(/\ABearer\s+/i, "")
      key if key.present? && key.length <= API_KEY_LIMIT
    end

    def self.warm_state?(state)
      state.to_s.start_with?(WARM_STATE_PREFIX)
    end

    def self.error_message(error)
      case error
      when HardcoverClient::ScopeError
        "#{error.message}. Create the key with the read:me:content, read:library, read:lists, and read:catalog permissions."
      when HardcoverClient::AuthenticationError
        "Hardcover rejected that key. Check that it is current and has not been revoked."
      when HardcoverClient::RateLimitError
        "Hardcover's rate limit was reached. Try again in a few minutes."
      when ConnectionManager::ConnectionChanged
        "Your Hardcover connection changed after this page was shown. Review it and try again."
      when Oauth::AuthorizationError
        "Hardcover did not accept the sign-in (#{error.message}). Check the client ID, secret, and registered redirect URI."
      else
        "Could not connect to Hardcover: #{error.message}"
      end
    end

    def initialize(session:, user:)
      @session = session
      @user = user
    end

    def connect_api_key(api_key, generation: nil)
      ConnectionManager.connect!(user: @user, auth_method: "personal_token", access_token: api_key, expected_generation: generation)
    end

    def start_oauth(base_url, warm: false, generation: nil)
      redirect_uri = HardcoverIntegration.redirect_uri(base_url)
      return unless HardcoverIntegration.redirect_uri_acceptable?(redirect_uri)

      state = "#{WARM_STATE_PREFIX if warm}#{SecureRandom.urlsafe_base64(32)}"
      verifier, challenge = Oauth.generate_pkce
      @session[OAUTH_KEY] = {
        "state" => state,
        "verifier" => verifier,
        "redirect_uri" => redirect_uri,
        "user_id" => @user.id,
        "expires_at" => Oauth::PENDING_TTL.from_now.to_i,
        **bound_to(generation)
      }
      Oauth.authorization_url(state: state, code_challenge: challenge, redirect_uri: redirect_uri)
    end

    def take_oauth(state)
      pending = @session.delete(OAUTH_KEY)
      return unless pending.is_a?(Hash)
      return unless pending["user_id"] == @user.id
      return if pending["expires_at"].to_i < Time.current.to_i

      pending if ActiveSupport::SecurityUtils.secure_compare(pending["state"].to_s, state.to_s)
    end

    def finish_oauth(pending, code)
      connect_tokens(Oauth.exchange_code(code: code, code_verifier: pending["verifier"], redirect_uri: pending["redirect_uri"]), pending)
    end

    def start_device(generation: nil)
      authorization = Oauth.start_device_authorization
      @session[DEVICE_KEY] = {
        "device_code" => authorization.device_code,
        "user_code" => authorization.user_code,
        "verification_uri" => authorization.verification_uri,
        "verification_uri_complete" => authorization.verification_uri_complete,
        "interval" => authorization.interval,
        "expires_at" => authorization.expires_at.to_i,
        "next_poll_at" => (Time.current + authorization.interval).to_i,
        "user_id" => @user.id,
        **bound_to(generation)
      }
    end

    def pending_device(warm: false)
      pending = @session[DEVICE_KEY]
      return unless pending.is_a?(Hash) && pending["user_id"] == @user.id
      return if pending["expires_at"].to_i < Time.current.to_i
      return if warm && !current?(pending)

      pending
    end

    def forget_device
      @session.delete(DEVICE_KEY)
    end

    def forget_sign_ins
      @session.delete(OAUTH_KEY)
      forget_device
    end

    def poll_device(warm: false)
      pending = pending_device
      return expired_device unless pending && (!warm || pending.key?("generation"))
      return replaced_device if warm && !current?(pending)
      return DevicePoll.new(status: :pending, message: nil, connection: nil) if Time.current.to_i < pending["next_poll_at"].to_i

      poll = Oauth.poll_device_authorization(pending["device_code"])
      case poll.status
      when :approved
        forget_device
        DevicePoll.new(status: :approved, message: nil, connection: connect_tokens(poll.token_set, pending))
      when :pending, :slow_down
        interval = pending["interval"].to_i + poll.interval.to_i
        @session[DEVICE_KEY] = pending.merge("interval" => interval, "next_poll_at" => (Time.current + interval).to_i)
        DevicePoll.new(status: :pending, message: nil, connection: nil)
      else
        forget_device
        DevicePoll.new(status: :failed, message: poll.status == :denied ? "Hardcover sign-in was declined." : "The sign-in code expired. Start again.", connection: nil)
      end
    rescue Oauth::Error, HardcoverClient::Error => e
      forget_device
      DevicePoll.new(status: :failed, message: self.class.error_message(e), connection: nil)
    end

    def remember_outcome(tone, message)
      @session[OUTCOME_KEY] = { "user_id" => @user.id, "tone" => tone, "message" => message.to_s.truncate(300), "expires_at" => OUTCOME_TTL.from_now.to_i }
    end

    def take_outcome
      outcome = @session.delete(OUTCOME_KEY)
      return unless outcome.is_a?(Hash) && outcome["user_id"] == @user.id
      return if outcome["expires_at"].to_i < Time.current.to_i

      { tone: outcome["tone"].to_s, message: outcome["message"].to_s }
    end

    private

    def current?(pending)
      pending.key?("generation") && pending["generation"] == ConnectionManager.sign_in_generation(@user)
    end

    def expired_device
      DevicePoll.new(status: :failed, message: "Hardcover sign-in expired. Start again.", connection: nil)
    end

    def replaced_device
      forget_device
      DevicePoll.new(status: :failed, message: self.class.error_message(ConnectionManager::ConnectionChanged.new), connection: nil)
    end

    def bound_to(generation)
      generation.nil? ? {} : { "generation" => generation }
    end

    def connect_tokens(token_set, pending)
      ConnectionManager.connect!(
        user: @user,
        auth_method: "oauth",
        access_token: token_set.access_token,
        refresh_token: token_set.refresh_token,
        expires_at: token_set.expires_at,
        scope: token_set.scope,
        expected_generation: pending["generation"]
      )
    end
  end
end
