# frozen_string_literal: true

module KoboAccountTestHelper
  WORKFLOW = "12345678-1234-1234-1234-123456789012"
  POLL_PATH = "/pt/pt/activateonweb/poll?workflowId=#{WORKFLOW}"
  STORE = "https://storeapi.kobo.com"
  AUTH = "https://auth.kobobooks.com"

  def create_kobo_account(user: users(:one), **attributes)
    user.kobo_accounts.create!({ name: "My Store account", device_id: "synthetic-device", serial_number: "synthetic-serial",
      activation_poll_url: POLL_PATH, activation_code: "123456", activation_expires_at: 10.minutes.from_now,
      next_poll_at: 1.second.ago }.merge(attributes))
  end

  def connect_kobo_account(**attributes)
    create_kobo_account(status: "connected", access_token: "synthetic-access", refresh_token: "synthetic-refresh",
      kobo_user_id: "synthetic-user-id", kobo_user_key: "synthetic-user-key", kobo_email: "reader@example.test", **attributes)
  end

  def stub_kobo_activation(poll: POLL_PATH, code: "123456")
    stub_request(:get, %r{\A#{Regexp.escape(AUTH)}/ActivateOnWeb\?}).to_return(body:
      %(<div data-poll-endpoint="#{poll.gsub('&', '&amp;')}"></div><img src="/qrcodegenerator/generate?url=activate%26code%3D#{code}">))
  end

  def stub_kobo_approval(status: "Complete", redirect: nil)
    redirect ||= "kobo://UserAuthenticated?#{URI.encode_www_form(userId: 'synthetic-user-id', userKey: 'synthetic-user-key', email: 'reader@example.test')}"
    stub_request(:post, AUTH + POLL_PATH).to_return(body: { Status: status, RedirectUrl: redirect }.to_json)
  end

  def kobo_tokens(access: "synthetic-access", refresh: "synthetic-refresh")
    { AccessToken: access, RefreshToken: refresh, TokenType: "Bearer" }.to_json
  end

  def stub_kobo_tokens
    stub_request(:post, STORE + "/v1/auth/device").with { |request|
      JSON.parse(request.body)["UserKey"] == "synthetic-user-key"
    }.to_return(body: kobo_tokens)
  end

  def kobo_book(id: "owned-book-1", title: "A Purchased Book", origin: "Purchased", removed: false)
    { "NewEntitlement" => { "BookEntitlement" => { "Id" => id, "OriginCategory" => origin, "IsRemoved" => removed },
      "BookMetadata" => { "RevisionId" => "edition-1", "Title" => title, "Contributors" => [ "An Author" ],
        "ContentType" => "EBook", "DownloadUrls" => [ { "Format" => "KEPUB", "Url" => "https://example.test/private-book-url" } ] } } }
  end

  def stub_kobo_catalogue(items: [ kobo_book ])
    stub_request(:get, STORE + "/v1/library/sync").to_return(body: items.to_json)
  end
end
