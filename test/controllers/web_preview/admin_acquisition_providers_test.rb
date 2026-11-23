# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/web_preview_test_helper"

class WebPreview::AdminAcquisitionProvidersTest < ActionDispatch::IntegrationTest
  include WebPreviewTestHelper

  TOKEN = "provider-bearer-7781aa"
  REPLACEMENT = "provider-bearer-9902bb"
  QUERY_SECRET = "querysecret5531"

  setup do
    @member = users(:one)
    @admin = users(:two)
    @previous_enabled = ENV[WebPreview::Access::VARIABLE]
    ENV[WebPreview::Access::VARIABLE] = [ @member, @admin ].map { |user| user.id.to_s }.join(",")
    AcquisitionProvider.delete_all
    @local = AcquisitionProvider.create!(name: "Local provider", url: "http://provider.test", api_key: TOKEN, priority: 0, timeout_seconds: 30)
    @comics = AcquisitionProvider.create!(name: "Comic shelf", url: "http://comics.test/api?key=#{QUERY_SECRET}", priority: 1, enabled: false,
      supports_ebooks: false, supports_audiobooks: false, supports_comicbooks: true, allow_private_network: true, timeout_seconds: 90)
  end

  teardown do
    ENV[WebPreview::Access::VARIABLE] = @previous_enabled
  end

  def providers_json(user: @admin)
    sign_in_as(user)
    preview_get web_preview_api_admin_acquisition_providers_path, user: user
    response.parsed_body
  end

  def write(verb, path, body = {}, user: @admin)
    public_send(verb, path, params: body.to_json, headers: account_headers(user).merge("Content-Type" => "application/json"))
    response.parsed_body
  end

  def version(provider)
    WebPreview::AcquisitionProviders.version(provider.reload)
  end

  def provider_path(provider)
    web_preview_api_admin_acquisition_provider_path(id: provider.id)
  end

  def probe_path(provider)
    web_preview_api_admin_acquisition_provider_test_path(id: provider.id)
  end

  def snapshot
    AcquisitionProvider.order(:id).map { |provider| provider.attributes.merge("api_key" => provider.api_key) }
  end

  def write_paths
    [
      [ :post, web_preview_api_admin_acquisition_providers_path, { provider: { name: "New", url: "http://new.test", supports_ebooks: true } } ],
      [ :put, provider_path(@local), { version: version(@local), provider: { name: "Renamed" } } ],
      [ :delete, provider_path(@local), { version: version(@local) } ],
      [ :post, probe_path(@local), {} ]
    ]
  end

  def changing_while(method_id, change:, &request)
    happened = false
    trace = TracePoint.new(:call) do |event|
      next if happened || event.defined_class != WebPreview::Admin::AcquisitionProvidersController || event.method_id != method_id

      happened = true
      change.call
    end
    trace.enable(&request)
    assert happened, "the change was not made during #{method_id}"
  end

  def with_log
    log = StringIO.new
    previous = Rails.logger
    previous_record_logger = ActiveRecord::Base.logger
    Rails.logger = ActiveSupport::Logger.new(log).tap { |logger| logger.level = :debug }
    ActionController::Base.logger = Rails.logger
    ActiveRecord::Base.logger = Rails.logger
    yield
    log.string
  ensure
    Rails.logger = previous
    ActionController::Base.logger = previous
    ActiveRecord::Base.logger = previous_record_logger
  end

  test "with the preview off, for a member, another account or signed out, nothing is read, written or contacted" do
    before = snapshot
    with_env(WebPreview::Access::VARIABLE => "") do
      sign_in_as(@admin)
      preview_get web_preview_api_admin_acquisition_providers_path, user: @admin
      assert_response :not_found
      write_paths.each do |verb, path, body|
        write(verb, path, body)
        assert_response :not_found, path
      end
    end

    sign_in_as(@member)
    preview_get web_preview_api_admin_acquisition_providers_path, user: @member
    assert_response :not_found
    assert_equal({ "error" => "not_found" }, response.parsed_body)
    write_paths.each do |verb, path, body|
      write(verb, path, body, user: @member)
      assert_response :not_found, path
    end

    sign_in_as(@admin)
    write_paths.each do |verb, path, body|
      write(verb, path, body, user: @member)
      assert_response :unauthorized, path
      assert_equal "account_changed", response.parsed_body.fetch("error")
    end

    delete session_path
    preview_get web_preview_api_admin_acquisition_providers_path, user: @admin
    assert_response :unauthorized
    write_paths.each do |verb, path, body|
      write(verb, path, body)
      assert_response :unauthorized, path
    end
    assert_equal before, snapshot
    assert_not_requested :any, /provider\.test|comics\.test/
  end

  test "every provider write needs the page's CSRF token" do
    before = snapshot
    sign_in_as(@admin)
    with_forgery_protection do
      write_paths.each do |verb, path, body|
        write(verb, path, body)
        assert_response :unprocessable_entity, path
        assert_equal "invalid_csrf", response.parsed_body.fetch("error")
      end
      assert_equal before, snapshot

      token = csrf_token
      put provider_path(@local), params: { version: version(@local), provider: { name: "Renamed" } }.to_json,
        headers: account_headers(@admin).merge("X-CSRF-Token" => token, "Content-Type" => "application/json")
      assert_response :success
    end
    assert_equal "Renamed", @local.reload.name
  end

  test "the list shows providers in classic order with the token only as a flag and the address without its query" do
    @tied = AcquisitionProvider.create!(name: "Another provider", url: "http://another.test", priority: 1)
    body = providers_json
    assert_response :success
    assert_equal "private, no-store", response.headers["Cache-Control"]
    [ TOKEN, QUERY_SECRET ].each { |secret| assert_not_includes response.body, secret }

    assert_equal AcquisitionProvider.by_priority.map(&:name), body.fetch("providers").map { |provider| provider.fetch("name") }
    assert_equal [ "Local provider", "Another provider", "Comic shelf" ], body.fetch("providers").map { |provider| provider.fetch("name") }
    assert_equal({
      "id" => @local.id.to_s, "version" => version(@local), "name" => "Local provider", "url" => "http://provider.test", "url_hidden" => false,
      "api_key_saved" => true, "enabled" => true, "allow_private_network" => false, "supports_ebooks" => true, "supports_audiobooks" => true,
      "supports_comicbooks" => false, "timeout_seconds" => 30, "priority" => 0
    }, body.dig("providers", 0))
    assert_equal({
      "id" => @comics.id.to_s, "version" => version(@comics), "name" => "Comic shelf", "url" => "http://comics.test/api", "url_hidden" => true,
      "api_key_saved" => false, "enabled" => false, "allow_private_network" => true, "supports_ebooks" => false, "supports_audiobooks" => false,
      "supports_comicbooks" => true, "timeout_seconds" => 90, "priority" => 1
    }, body.dig("providers", 2))
    assert_equal({ "enabled" => true, "allow_private_network" => false, "supports_ebooks" => true, "supports_audiobooks" => true, "supports_comicbooks" => false, "timeout_seconds" => 30 },
      body.fetch("defaults"))
  end

  test "adding a provider saves what the classic form saves and takes the last place" do
    body = providers_json
    assert_response :success
    write :post, web_preview_api_admin_acquisition_providers_path, { provider: {
      name: "Home provider", url: " http://home.test:4567/ ", api_key: "home-secret-31", enabled: true, allow_private_network: false,
      supports_ebooks: true, supports_audiobooks: false, supports_comicbooks: true, timeout_seconds: "45", priority: 0
    } }
    assert_response :created
    created = AcquisitionProvider.find_by!(name: "Home provider")
    assert_equal created.id.to_s, response.parsed_body.fetch("created")
    assert_equal [ "http://home.test:4567", "home-secret-31", true, false, true, false, true, 45, 2 ],
      [ created.url, created.api_key, created.supports_ebooks, created.supports_audiobooks, created.supports_comicbooks, created.allow_private_network, created.enabled, created.timeout_seconds, created.priority ]
    assert_equal({ "tone" => "success", "message" => "Provider “Home provider” added." }, response.parsed_body.fetch("outcome"))
    assert_equal "Home provider", response.parsed_body.fetch("providers").last.fetch("name")
    assert_not_includes response.body, "home-secret-31"
    assert_equal body.fetch("defaults"), response.parsed_body.fetch("defaults")
  end

  test "a provider is accepted or refused exactly when the classic form accepts or refuses it" do
    attempts = [
      { name: "", url: "http://x.test" },
      { name: "Local provider", url: "http://x.test" },
      { name: "No scheme", url: "ftp://x.test" },
      { name: "With sign-in", url: "http://user:pass@x.test" },
      { name: "Nothing", url: "http://x.test", supports_ebooks: "0", supports_audiobooks: "0", supports_comicbooks: "0" },
      { name: "Too slow", url: "http://x.test", timeout_seconds: "121" },
      { name: "Too quick", url: "http://x.test", timeout_seconds: "0" },
      { name: "Huge", url: "http://x.test", timeout_seconds: "99999999999999999999999" },
      { name: "Local without permission", url: "http://192.168.1.20:4567" },
      { name: "Loopback without permission", url: "http://localhost:4567" },
      { name: "Local with permission", url: "http://192.168.1.20:4567", allow_private_network: "1" }
    ]
    sign_in_as(@admin)
    attempts.each do |attributes|
      AcquisitionProvider.where.not(id: [ @local.id, @comics.id ]).delete_all
      post admin_acquisition_providers_url, params: { acquisition_provider: { supports_ebooks: "1", timeout_seconds: "30" }.merge(attributes) }
      classic = response.status
      classic_saved = AcquisitionProvider.where.not(id: [ @local.id, @comics.id ]).pluck(:name, :url)
      AcquisitionProvider.where.not(id: [ @local.id, @comics.id ]).delete_all

      write :post, web_preview_api_admin_acquisition_providers_path, { provider: { supports_ebooks: "1", timeout_seconds: "30" }.merge(attributes) }
      assert_equal classic == 302 ? 201 : 422, response.status, attributes.inspect
      assert_equal classic_saved, AcquisitionProvider.where.not(id: [ @local.id, @comics.id ]).pluck(:name, :url), attributes.inspect
    end

    write :post, web_preview_api_admin_acquisition_providers_path, { provider: { name: "", url: "http://localhost:1", supports_ebooks: false, supports_audiobooks: false, supports_comicbooks: false, timeout_seconds: "500" } }
    assert_response :unprocessable_entity
    assert_equal [
      { "field" => "name", "message" => "Name can't be blank" },
      { "field" => "timeout_seconds", "message" => "Timeout must be less than or equal to 120" },
      { "field" => "url", "message" => "Address points to a private network address. Enable \"Allow private network\" if this provider runs on your local network." },
      { "field" => "base", "message" => "Provider must support ebooks, audiobooks, or Comics & Manga" }
    ], response.parsed_body.fetch("errors")
  end

  test "values of the wrong shape are refused before anything is written" do
    sign_in_as(@admin)
    before = snapshot
    [
      { provider: { name: [ "Odd" ], url: "http://x.test" } },
      { provider: { name: "Odd", url: "http://x.test", api_key: nil } },
      { provider: { name: nil, url: "http://x.test" } },
      { provider: { name: "Odd", url: "http://x.test", enabled: "maybe" } },
      { provider: { name: "Odd", url: "http://x.test", timeout_seconds: 30.5 } },
      { provider: "name=Odd" },
      { name: "Unwrapped", url: "http://x.test" }
    ].each do |body|
      write :post, web_preview_api_admin_acquisition_providers_path, body
      assert_response :bad_request, body.inspect
      assert_equal "invalid_request", response.parsed_body.fetch("error")
    end

    write :put, provider_path(@local), { provider: { name: "No version" } }
    assert_response :bad_request
    write :put, provider_path(@local), { version: version(@local), provider: { name: "Renamed", api_key: nil } }
    assert_response :bad_request
    write :delete, provider_path(@local), {}
    assert_response :bad_request

    post "#{web_preview_api_admin_acquisition_providers_path}?#{{ provider: { name: "From the address", url: "http://q.test" } }.to_query}", params: "{}", headers: account_headers(@admin).merge("Content-Type" => "application/json")
    assert_response :bad_request

    post web_preview_api_admin_acquisition_providers_path, params: %({,"api_key":"#{REPLACEMENT}"}), headers: account_headers(@admin).merge("Content-Type" => "application/json")
    assert_response :bad_request
    assert_equal before, snapshot
  end

  test "saving keeps a blank token, replaces a typed one and changes only what was sent" do
    sign_in_as(@admin)
    write :put, provider_path(@local), { version: version(@local), provider: { name: "Local", api_key: "" } }
    assert_response :success
    assert_equal [ "Local", TOKEN, "http://provider.test" ], [ @local.reload.name, @local.api_key, @local.url ]
    assert_equal "Provider “Local” saved.", response.parsed_body.dig("outcome", "message")

    write :put, provider_path(@local), { version: version(@local), provider: { api_key: REPLACEMENT, supports_audiobooks: false, timeout_seconds: 12, enabled: "0" } }
    assert_response :success
    assert_equal [ REPLACEMENT, false, 12, false, true ], [ @local.reload.api_key, @local.supports_audiobooks, @local.timeout_seconds, @local.enabled, @local.supports_ebooks ]
    assert_not_includes response.body, REPLACEMENT

    write :put, provider_path(@comics), { version: version(@comics), provider: { name: "Comics" } }
    assert_equal [ "Comics", "http://comics.test/api?key=#{QUERY_SECRET}" ], [ @comics.reload.name, @comics.url ]

    write :put, provider_path(@comics), { version: version(@comics), provider: { name: "Comics" } }
    assert_equal "There were no changes to save.", response.parsed_body.dig("outcome", "message")

    write :put, provider_path(@local), { version: version(@local), provider: { priority: 7 } }
    assert_equal 0, @local.reload.priority

    write :put, provider_path(@local), { version: version(@local), provider: { name: "Comics" } }
    assert_response :unprocessable_entity
    assert_equal [ { "field" => "name", "message" => "Name has already been taken" } ], response.parsed_body.fetch("errors")
    assert_equal "Local", @local.reload.name
  end

  test "a save or removal of a provider changed or removed since it was read changes nothing" do
    sign_in_as(@admin)
    stale = version(@local)
    @local.update!(name: "Changed elsewhere")

    write :put, provider_path(@local), { version: stale, provider: { name: "Mine", api_key: REPLACEMENT } }
    assert_response :conflict
    assert_equal "provider_changed", response.parsed_body.fetch("error")
    assert_equal "Changed elsewhere", response.parsed_body.dig("providers", 0, "name")
    assert_equal [ "Changed elsewhere", TOKEN ], [ @local.reload.name, @local.api_key ]

    write :delete, provider_path(@local), { version: stale }
    assert_response :conflict
    assert AcquisitionProvider.exists?(@local.id)

    current = version(@comics)
    @comics.destroy!
    write :put, provider_path(@comics), { version: current, provider: { name: "Gone" } }
    assert_response :not_found
    write :delete, provider_path(@comics), { version: current }
    assert_response :not_found
  end

  test "an administrator demoted or removed while a write is on its way changes nothing" do
    changes = { demote: -> { User.find(@admin.id).update!(role: :user) }, remove: -> { User.find(@admin.id).soft_delete! } }
    writes = {
      submitted: -> { write :post, web_preview_api_admin_acquisition_providers_path, { provider: { name: "Late", url: "http://late.test", supports_ebooks: true } } },
      expected_version: -> { write :put, provider_path(@local), { version: version(@local), provider: { name: "Late" } } }
    }
    changes.each do |change_name, change|
      writes.each do |method_id, request|
        @admin.update_columns(role: User.roles[:admin], deleted_at: nil)
        sign_in_as(@admin)
        before = snapshot
        changing_while(method_id, change: change, &request)
        assert_response :not_found, "#{method_id} after #{change_name}"
        assert_equal before, snapshot, "#{method_id} after #{change_name}"
      end
    end

    @admin.update_columns(role: User.roles[:admin], deleted_at: nil)
    sign_in_as(@admin)
    current = version(@local)
    changing_while(:expected_version, change: changes[:demote]) { write :delete, provider_path(@local), { version: current } }
    assert_response :not_found
    assert AcquisitionProvider.exists?(@local.id)

    @admin.update_columns(role: User.roles[:admin], deleted_at: nil)
    sign_in_as(@admin)
    VCR.turned_off do
      health = stub_request(:get, "http://provider.test/health").to_return(status: 204)
      changing_while(:find, change: changes[:demote]) { write :post, probe_path(@local) }
      assert_response :not_found
      assert_not_requested health
    end
  end

  test "removing a provider removes it like the classic form and keeps the results it found without it" do
    result = requests(:pending_request).search_results.create!(guid: "provider-result-1", title: "Found", source: SearchResult::SOURCE_CUSTOM,
      acquisition_provider: @local, provider_result_id: "r1", provider_payload: { "download_type" => "direct" })
    assert result.downloadable?
    sign_in_as(@admin)
    write :delete, provider_path(@local), { version: version(@local) }
    assert_response :success
    assert_equal "Provider “Local provider” removed.", response.parsed_body.dig("outcome", "message")
    assert_not AcquisitionProvider.exists?(@local.id)
    assert_nil result.reload.acquisition_provider_id
    assert_not result.downloadable?
    assert_equal [ "Comic shelf" ], response.parsed_body.fetch("providers").map { |provider| provider.fetch("name") }
  end

  test "Test calls the saved provider's health address with its saved token and says what happened" do
    sign_in_as(@admin)
    VCR.turned_off do
      health = stub_request(:get, "http://provider.test/health").with(headers: { "Authorization" => "Bearer #{TOKEN}" }).to_return(status: 204)
      write :post, probe_path(@local), { provider: { url: "http://elsewhere.test", api_key: "typed-not-saved" } }
      assert_response :success
      assert_requested health
      assert_not_requested :get, "http://elsewhere.test/health"
      assert_equal({ "tone" => "success", "message" => "Connection successful." }, response.parsed_body.fetch("outcome"))
      assert_equal @local.id.to_s, response.parsed_body.fetch("tested")

      stub_request(:get, "http://provider.test/health").to_return(status: 500)
      write :post, probe_path(@local)
      assert_equal({ "tone" => "error", "message" => "Connection failed: the health check did not answer with success." }, response.parsed_body.fetch("outcome"))

      stub_request(:get, "http://provider.test/health").to_raise(Errno::ECONNREFUSED)
      write :post, probe_path(@local)
      assert_equal "Connection failed: Connection refused.", response.parsed_body.dig("outcome", "message")

      stub_request(:get, "http://provider.test/health").to_timeout
      write :post, probe_path(@local)
      assert_equal "Connection failed: Connection timed out.", response.parsed_body.dig("outcome", "message")

      stub_request(:get, "http://provider.test/health").to_raise(Net::HTTPBadResponse.new("bad #{TOKEN}"))
      write :post, probe_path(@local)
      assert_equal "Connection failed: the provider did not answer as expected.", response.parsed_body.dig("outcome", "message")
    end
    assert_not_includes response.body, TOKEN
  end

  test "Test refuses private and blocked addresses unless the provider allows private networks, as searches do" do
    sign_in_as(@admin)
    previous = OutboundUrlGuard.resolver
    VCR.turned_off do
      OutboundUrlGuard.resolver = ->(_host) { [ "10.0.0.5" ] }
      write :post, probe_path(@local)
      assert_equal "Connection failed: the address is on a private network. Turn on Allow private network if this provider runs on your local network.",
        response.parsed_body.dig("outcome", "message")

      @local.update!(allow_private_network: true)
      stub_request(:get, "http://provider.test/health").to_return(status: 200)
      write :post, probe_path(@local)
      assert_equal "success", response.parsed_body.dig("outcome", "tone")

      OutboundUrlGuard.resolver = ->(_host) { [ "169.254.169.254" ] }
      write :post, probe_path(@local)
      assert_equal "Connection failed: Shelfarr does not contact that address.", response.parsed_body.dig("outcome", "message")

      OutboundUrlGuard.resolver = ->(_host) { [] }
      write :post, probe_path(@local)
      assert_equal "Connection failed: Could not resolve host.", response.parsed_body.dig("outcome", "message")
    end
  ensure
    OutboundUrlGuard.resolver = previous
  end

  test "Test answers never repeat the provider's name, so a token copied into it cannot come back" do
    @local.update_columns(name: "Local abc #{QUERY_SECRET}")
    @local.update!(api_key: "abc", url: "http://provider.test/?k=#{QUERY_SECRET}")
    sign_in_as(@admin)
    VCR.turned_off do
      stub_request(:get, %r{\Ahttp://provider\.test/}).to_return(status: 500)
      write :post, probe_path(@local)
    end
    assert_equal({ "tone" => "error", "message" => "Connection failed: the health check did not answer with success." }, response.parsed_body.fetch("outcome"))
  end

  test "tokens and addresses are not written to the log, even at debug level" do
    sign_in_as(@admin)
    file = Rails.root.join("log/test.log")
    start = File.size?(file).to_i
    log = with_log do
      write :post, web_preview_api_admin_acquisition_providers_path, { provider: { name: "Logged", url: "http://logged.test/?k=#{QUERY_SECRET}", api_key: REPLACEMENT, supports_ebooks: true } }
      write :put, provider_path(@local), { version: version(@local), provider: { api_key: REPLACEMENT, url: "http://changed.test/?k=#{QUERY_SECRET}" } }
      assert_response :success
      post web_preview_api_admin_acquisition_providers_path, params: %({,"api_key":"#{REPLACEMENT}"}),
        headers: account_headers(@admin).merge("Content-Type" => "application/json")
      assert_response :bad_request
      post "#{web_preview_api_admin_acquisition_providers_path}?provider%5Burl%5D=http%3A%2F%2Fq.test%2F%3Fk%3D#{QUERY_SECRET}&provider[url]=#{QUERY_SECRET}", params: "{}",
        headers: account_headers(@admin).merge("Content-Type" => "application/json")
      assert_response :bad_request
    end
    assert_includes log, "WebPreview::Admin::AcquisitionProvidersController#create"
    assert_includes log, "WebPreview::Admin::AcquisitionProvidersController#update"
    assert_equal [ "http://logged.test/?k=#{QUERY_SECRET}", "http://changed.test/?k=#{QUERY_SECRET}" ], [ AcquisitionProvider.find_by!(name: "Logged").url, @local.reload.url ]
    application_log = File.binread(file, nil, start).to_s
    assert_not_includes log, REPLACEMENT
    assert_not_includes log, QUERY_SECRET
    assert_not_includes application_log, REPLACEMENT
  end

  test "old provider addresses open the matching card for preview administrators" do
    sign_in_as(@admin)
    get admin_acquisition_providers_path
    assert_redirected_to web_preview_server_category_path(category: "sources", anchor: "acquisition_providers")
    get new_admin_acquisition_provider_path
    assert_redirected_to web_preview_server_category_path(category: "sources", anchor: "acquisition_providers-new")
    get admin_acquisition_provider_path(@local)
    assert_redirected_to web_preview_server_category_path(category: "sources", anchor: "acquisition-provider-#{@local.id}")
    get edit_admin_acquisition_provider_path(@local)
    assert_redirected_to web_preview_server_category_path(category: "sources", anchor: "acquisition-provider-#{@local.id}-edit")
    get admin_acquisition_provider_path(id: 999_999)
    assert_response :not_found
    get web_preview_server_category_path(category: "sources")
    assert_response :success
    assert_select "#shelfarr-boot"
    get "/admin/acquisition_providers/#{@local.id}/edit", env: { "SCRIPT_NAME" => "/shelf" }
    assert_redirected_to "http://www.example.com/shelf/preview/server/sources#acquisition-provider-#{@local.id}-edit"
  end

  test "old provider addresses stay classic with the preview off, for unlisted administrators, without the stylesheet and after a classic form" do
    sign_in_as(@admin)
    with_env(WebPreview::Access::VARIABLE => nil) do
      get admin_acquisition_providers_path
      assert_response :success
      assert_select "h1", "Acquisition Providers"
    end
    with_env(WebPreview::Access::VARIABLE => @member.id.to_s) do
      get edit_admin_acquisition_provider_path(@local)
      assert_response :success
      assert_select "h1", "Edit Acquisition Provider"
    end
    head admin_acquisition_provider_path(@local)
    assert_response :success
    WarmEntry.stub(:stylesheet_built?, false) do
      get new_admin_acquisition_provider_path
      assert_response :success
      assert_select "h1", "New Acquisition Provider"
    end

    VCR.turned_off do
      stub_request(:get, "http://provider.test/health").to_return(status: 204)
      post test_admin_acquisition_provider_path(@local)
    end
    follow_redirect!
    assert_response :success
    assert_select "h1", "Acquisition Providers"

    sign_in_as(@member)
    get admin_acquisition_providers_path
    assert_redirected_to root_path
  end
end
