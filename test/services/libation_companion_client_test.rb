# frozen_string_literal: true

require "test_helper"
require "tempfile"
require "tmpdir"

class LibationCompanionClientTest < ActiveSupport::TestCase
  setup do
    @connection = OwnedLibraryConnection.create!(
      url: "https://libation.test",
      allow_private_network: false,
      bridge_token: "database-token",
      timeout_seconds: 5
    )
    @client = @connection.client
  end

  test "health is unauthenticated" do
    VCR.turned_off do
      stub_request(:get, "https://libation.test/health")
        .with { |request| request.headers["Authorization"].blank? }
        .to_return(status: 200, body: { status: "ok" }.to_json)

      assert_equal "ok", @client.health["status"]
    end
  end

  test "version uses bearer authentication" do
    VCR.turned_off do
      stub_request(:get, "https://libation.test/version")
        .with(headers: { "Authorization" => "Bearer database-token" })
        .to_return(
          status: 200,
          body: { companionVersion: "0.1.0", libationVersion: "13.5.0" }.to_json
        )

      version = @client.version
      assert_equal "0.1.0", version.companion_version
      assert_equal "13.5.0", version.libation_version
    end
  end

  test "version rejects a non-object response" do
    VCR.turned_off do
      stub_request(:get, "https://libation.test/version")
        .to_return(status: 200, body: [].to_json)

      assert_raises(LibationCompanionClient::ResponseError) { @client.version }
    end
  end

  test "distinguishes a busy companion from an unavailable companion" do
    VCR.turned_off do
      stub_request(:get, "https://libation.test/v1/accounts")
        .to_return(status: 409, body: { error: "busy" }.to_json)

      error = assert_raises(LibationCompanionClient::BusyError) { @client.accounts }
      assert_match(/busy/, error.message)
    end
  end

  test "maps queue capacity responses to an actionable busy error" do
    VCR.turned_off do
      stub_request(:post, "https://libation.test/v1/sync")
        .to_return(status: 429, body: { error: "capacity" }.to_json)

      error = assert_raises(LibationCompanionClient::BusyError) { @client.start_sync }
      assert_match(/queue is full/, error.message)
    end
  end

  test "maps ineligible backup responses without exposing companion output" do
    VCR.turned_off do
      stub_request(:post, "https://libation.test/v1/backups/B012345678")
        .to_return(status: 422, body: { error: "secret upstream detail" }.to_json)

      error = assert_raises(LibationCompanionClient::ResponseError) do
        @client.start_backup("B012345678")
      end
      assert_match(/ineligible/, error.message)
      assert_no_match(/secret upstream detail/, error.message)
    end
  end

  test "refuses to send a bearer token over public HTTP" do
    @connection.update!(
      url: "http://public-companion.example",
      allow_private_network: true,
      bridge_token: "public-token"
    )

    VCR.turned_off do
      assert_raises(LibationCompanionClient::ConnectionError) do
        @connection.client.version
      end
      assert_not_requested :get, "http://public-companion.example/version"
    end
  end

  test "mounted token file takes precedence over encrypted database fallback" do
    Tempfile.create("libation-token") do |file|
      file.write("file-token\n")
      file.flush

      with_env(
        "SHELFARR_LIBATION_TOKEN_FILE" => file.path,
        "SHELFARR_LIBATION_URL" => "https://libation.test"
      ) do
        VCR.turned_off do
          stub_request(:get, "https://libation.test/version")
            .with(headers: { "Authorization" => "Bearer file-token" })
            .to_return(status: 200, body: {}.to_json)

          assert_nothing_raised { @client.version }
        end
      end
    end
  end

  test "mounted token file cannot be a symlink into Shelfarr private state" do
    Dir.mktmpdir("libation-token-link") do |directory|
      private_file = File.join(directory, "shelfarr-secret")
      token_link = File.join(directory, "token")
      File.binwrite(private_file, "rails-private-secret")
      File.symlink(private_file, token_link)

      with_env("SHELFARR_LIBATION_TOKEN_FILE" => token_link) do
        error = assert_raises(LibationCompanionClient::NotConfiguredError) do
          @client.send(:token_from_file)
        end
        assert_match(/cannot be read/, error.message)
      end
    end
  end

  test "mounted token file rejects a FIFO without blocking" do
    skip "mkfifo is unavailable" unless File.respond_to?(:mkfifo)

    Dir.mktmpdir("libation-token-fifo") do |directory|
      token_path = File.join(directory, "token")
      File.mkfifo(token_path, 0o600)

      with_env("SHELFARR_LIBATION_TOKEN_FILE" => token_path) do
        error = assert_raises(LibationCompanionClient::NotConfiguredError) do
          @client.send(:token_from_file)
        end
        assert_match(/invalid|cannot be read/, error.message)
      end
    end
  end

  test "mounted token is read from one descriptor if its pathname is replaced" do
    Dir.mktmpdir("libation-token-swap") do |directory|
      token_path = File.join(directory, "token")
      private_file = File.join(directory, "shelfarr-secret")
      File.binwrite(token_path, "original-token\n")
      File.binwrite(private_file, "rails-private-secret")
      original_open = File.method(:open)
      swapping_open = lambda do |path, flags, &block|
        original_open.call(path, flags) do |descriptor|
          File.unlink(token_path)
          File.symlink(private_file, token_path)
          block.call(descriptor)
        end
      end

      with_env("SHELFARR_LIBATION_TOKEN_FILE" => token_path) do
        File.stub(:open, swapping_open) do
          assert_equal "original-token", @client.send(:token_from_file)
        end
      end
    end
  end

  test "mounted token is never sent to a different companion URL" do
    Tempfile.create("libation-token") do |file|
      file.write("bundled-token\n")
      file.flush

      with_env(
        "SHELFARR_LIBATION_TOKEN_FILE" => file.path,
        "SHELFARR_LIBATION_URL" => "http://shelfarr-libation:8080"
      ) do
        VCR.turned_off do
          stub_request(:get, "https://libation.test/version")
            .with(headers: { "Authorization" => "Bearer database-token" })
            .to_return(status: 200, body: {}.to_json)

          assert_nothing_raised { @client.version }
          assert_not @client.token_file_managed?
        end
      end
    end
  end

  test "parses accounts with camel case fields" do
    VCR.turned_off do
      stub_request(:get, "https://libation.test/v1/accounts")
        .to_return(
          status: 200,
          body: {
            accounts: [
              { account: "reader@example.com", locale: "us", authenticated: true, scanLibrary: true }
            ]
          }.to_json
        )

      account = @client.accounts.first
      assert_equal "reader@example.com", account.account
      assert_equal "us", account.locale
      assert account.authenticated
      assert account.scan_enabled
    end
  end

  test "starts browser authentication with strict marketplace values" do
    VCR.turned_off do
      stub_request(:post, "https://libation.test/v1/auth/start")
        .with do |request|
          JSON.parse(request.body) == { "account" => "reader@example.com", "locale" => "uk" }
        end
        .to_return(
          status: 200,
          body: {
            sessionId: "session-1",
            loginUrl: "https://www.amazon.co.uk/ap/signin?example=1",
            expiresAt: 10.minutes.from_now.iso8601
          }.to_json
        )

      auth = @client.start_auth(account: "reader@example.com", locale: "uk")
      assert_equal "session-1", auth.session_id
      assert_equal "https://www.amazon.co.uk/ap/signin?example=1", auth.login_url
      assert_not auth.authenticated
    end

    assert_raises(ArgumentError) do
      @client.start_auth(account: "reader@example.com", locale: "brazil")
    end
  end

  test "accepts already authenticated response without a new login session" do
    VCR.turned_off do
      stub_request(:post, "https://libation.test/v1/auth/start")
        .to_return(status: 200, body: { status: "authenticated" }.to_json)

      auth = @client.start_auth(account: "reader@example.com", locale: "us")
      assert auth.authenticated
      assert_nil auth.session_id
      assert_nil auth.login_url
    end
  end

  test "rejects a login URL outside expected Amazon and Audible hosts" do
    VCR.turned_off do
      stub_request(:post, "https://libation.test/v1/auth/start")
        .to_return(
          status: 200,
          body: { sessionId: "session-1", loginUrl: "https://attacker.test/signin" }.to_json
        )

      assert_raises(LibationCompanionClient::ResponseError) do
        @client.start_auth(account: "reader@example.com", locale: "us")
      end
    end
  end

  test "completes browser authentication with camel case fields" do
    VCR.turned_off do
      stub_request(:post, "https://libation.test/v1/auth/complete")
        .with do |request|
          JSON.parse(request.body) == {
            "sessionId" => "session-1",
            "responseUrl" => "https://www.amazon.com/ap/maplanding?example=1"
          }
        end
        .to_return(status: 204)

      assert_equal({}, @client.complete_auth(
        session_id: "session-1",
        response_url: "https://www.amazon.com/ap/maplanding?example=1"
      ))
    end
  end

  test "parses normalized library entries" do
    VCR.turned_off do
      stub_request(:get, "https://libation.test/v1/library?limit=250&offset=0")
        .to_return(
          status: 200,
          body: {
            items: [
              {
                asin: "B012345678",
                title: "A Title",
                authors: [ { name: "An Author" } ],
                narrators: [ "A Narrator" ],
                lengthMinutes: 2,
                isAudiblePlus: true,
                absentFromLastScan: false,
                bookStatus: "Liberated",
                dateAdded: "2026-01-02T03:04:05Z",
                filePath: "/data/Author/A Title.m4b"
              }
            ]
          }.to_json
        )

      entry = @client.library.first
      assert_equal "B012345678", entry.external_id
      assert_equal [ "An Author" ], entry.authors
      assert_equal [ "A Narrator" ], entry.narrators
      assert_equal 120, entry.duration_seconds
      assert_equal "subscription", entry.ownership_type
      assert entry.active
      assert entry.downloaded
      assert_equal Time.zone.parse("2026-01-02T03:04:05Z"), entry.purchased_at
      assert_equal "/data/Author/A Title.m4b", entry.file_path
      assert_equal({ "bookStatus" => "Liberated" }, entry.payload)
    end
  end

  test "rejects malformed or oversized normalized library fields" do
    invalid_entries = [
      { asin: "not-an-asin", title: "Invalid identifier" },
      { asin: "B012345678", title: "x" * (LibationCompanionClient::MAX_TITLE_BYTES + 1) },
      { asin: "B012345678", title: "Invalid boolean", isPurchased: "definitely" },
      { asin: "B012345678", title: "Invalid duration", durationSeconds: "1.5" },
      { asin: "B012345678", title: "Invalid timestamp", purchasedAt: "not-a-time" }
    ]

    invalid_entries.each_with_index do |entry, index|
      VCR.turned_off do
        stub_request(:get, "https://libation.test/v1/library?limit=250&offset=0")
          .to_return(status: 200, body: { items: [ entry ] }.to_json)

        assert_raises(LibationCompanionClient::ResponseError, "entry #{index}") do
          @client.library
        end
      end
    end
  end

  test "rejects duplicate ASINs instead of reconciling inconsistent ownership" do
    first_items = 250.times.map do |index|
      { asin: format("B%09d", index), title: "Title #{index}" }
    end

    VCR.turned_off do
      stub_request(:get, "https://libation.test/v1/library?limit=250&offset=0")
        .to_return(status: 200, body: {
          generatedAt: "2026-07-18T10:00:00Z",
          items: first_items,
          offset: 0,
          limit: 250,
          totalItems: 251,
          nextOffset: 250
        }.to_json)
      stub_request(:get, "https://libation.test/v1/library?limit=250&offset=250")
        .to_return(status: 200, body: {
          generatedAt: "2026-07-18T10:00:00Z",
          items: [ { asin: "B000000000", title: "Conflicting duplicate" } ],
          offset: 250,
          limit: 250,
          totalItems: 251,
          nextOffset: nil
        }.to_json)

      error = assert_raises(LibationCompanionClient::ResponseError) { @client.library }
      assert_match(/duplicate Audible ASIN/, error.message)
    end
  end

  test "rejects a legacy library beyond the bounded reconciliation budget" do
    entries = Array.new(LibationCompanionClient::MAX_LIBRARY_ITEMS + 1)

    error = assert_raises(LibationCompanionClient::ResponseError) do
      @client.send(:append_library_entries!, [], entries, {})
    end
    assert_match(/title limit/, error.message)
  end

  test "rejects a page containing more items than its declared limit" do
    entries = 2.times.map do |index|
      { asin: format("B%09d", index), title: "Title #{index}" }
    end

    VCR.turned_off do
      stub_request(:get, "https://libation.test/v1/library?limit=250&offset=0")
        .to_return(status: 200, body: {
          generatedAt: "2026-07-18T10:00:00Z",
          items: entries,
          offset: 0,
          limit: 1,
          totalItems: 2,
          nextOffset: nil
        }.to_json)

      assert_raises(LibationCompanionClient::ResponseError) { @client.library }
    end
  end

  test "rejects an underfilled nonterminal page before it can amplify requests" do
    VCR.turned_off do
      stub_request(:get, "https://libation.test/v1/library?limit=250&offset=0")
        .to_return(status: 200, body: {
          generatedAt: "2026-07-18T10:00:00Z",
          items: [ { asin: "B000000000", title: "Only one" } ],
          offset: 0,
          limit: 250,
          totalItems: 251,
          nextOffset: 1
        }.to_json)

      error = assert_raises(LibationCompanionClient::ResponseError) { @client.library }
      assert_match(/inconsistent library page/, error.message)
      assert_requested :get, "https://libation.test/v1/library?limit=250&offset=0", times: 1
      assert_not_requested :get, %r{/v1/library\?.*offset=1}
    end
  end

  test "shares a finite page request budget across the full library read" do
    first_items = 250.times.map do |index|
      { asin: format("B%09d", index), title: "Title #{index}" }
    end
    budget = LibationCompanionClient::LibraryReadBudget.new(
      max_requests: 1,
      max_response_bytes: 1.megabyte
    )

    VCR.turned_off do
      stub_request(:get, "https://libation.test/v1/library?limit=250&offset=0")
        .to_return(status: 200, body: {
          generatedAt: "2026-07-18T10:00:00Z",
          items: first_items,
          offset: 0,
          limit: 250,
          totalItems: 251,
          nextOffset: 250
        }.to_json)

      @client.stub(:build_library_read_budget, budget) do
        error = assert_raises(LibationCompanionClient::ResponseError) { @client.library }
        assert_match(/page request budget/, error.message)
      end
      assert_not_requested :get, "https://libation.test/v1/library?limit=250&offset=250"
    end
  end

  test "counts ignored fields against the aggregate library response budget" do
    body = {
      items: [ { asin: "B012345678", title: "A Title" } ],
      ignoredPadding: "x" * 1_000
    }.to_json
    budget = LibationCompanionClient::LibraryReadBudget.new(
      max_requests: 1,
      max_response_bytes: body.bytesize - 1
    )

    VCR.turned_off do
      stub_request(:get, "https://libation.test/v1/library?limit=250&offset=0")
        .to_return(status: 200, body: body)

      @client.stub(:build_library_read_budget, budget) do
        error = assert_raises(LibationCompanionClient::ResponseError) { @client.library }
        assert_match(/aggregate response budget/, error.message)
      end
    end
  end

  test "rejects an oversized library page before reading its declared body" do
    VCR.turned_off do
      stub_request(:get, "https://libation.test/v1/library?limit=250&offset=0")
        .to_return(
          status: 200,
          headers: {
            "Content-Length" => (LibationCompanionClient::MAX_RESPONSE_BYTES + 1).to_s
          },
          body: ""
        )

      error = assert_raises(LibationCompanionClient::ResponseError) { @client.library }
      assert_match(/response exceeds/, error.message)
    end
  end

  test "reads a large library in bounded snapshot-consistent pages" do
    first_items = 250.times.map do |index|
      { asin: format("B%09d", index), title: "Title #{index}" }
    end
    second_items = [ { asin: "B000000250", title: "Title 250" } ]

    VCR.turned_off do
      stub_request(:get, "https://libation.test/v1/library?limit=250&offset=0")
        .to_return(status: 200, body: {
          generatedAt: "2026-07-18T10:00:00Z",
          items: first_items,
          offset: 0,
          limit: 250,
          totalItems: 251,
          nextOffset: 250
        }.to_json)
      stub_request(:get, "https://libation.test/v1/library?limit=250&offset=250")
        .to_return(status: 200, body: {
          generatedAt: "2026-07-18T10:00:00Z",
          items: second_items,
          offset: 250,
          limit: 250,
          totalItems: 251,
          nextOffset: nil
        }.to_json)

      entries = @client.library
      assert_equal 251, entries.length
      assert_equal "B000000000", entries.first.external_id
      assert_equal "B000000250", entries.last.external_id
    end
  end

  test "restarts pagination once when a sync replaces the snapshot between pages" do
    first_items = 250.times.map do |index|
      { asin: format("B%09d", index), title: "Title #{index}" }
    end
    first_page = ->(generated_at) {
      {
        generatedAt: generated_at,
        items: first_items,
        offset: 0,
        limit: 250,
        totalItems: 251,
        nextOffset: 250
      }.to_json
    }
    final_page = ->(generated_at) {
      {
        generatedAt: generated_at,
        items: [ { asin: "B000000250", title: "Last" } ],
        offset: 250,
        limit: 250,
        totalItems: 251,
        nextOffset: nil
      }.to_json
    }

    VCR.turned_off do
      stub_request(:get, "https://libation.test/v1/library?limit=250&offset=0")
        .to_return(
          { status: 200, body: first_page.call("2026-07-18T10:00:00Z") },
          { status: 200, body: first_page.call("2026-07-18T11:00:00Z") }
        )
      stub_request(:get, "https://libation.test/v1/library?limit=250&offset=250")
        .to_return(
          { status: 200, body: final_page.call("2026-07-18T11:00:00Z") },
          { status: 200, body: final_page.call("2026-07-18T11:00:00Z") }
        )

      entries = @client.library
      assert_equal 251, entries.length
      assert_equal "B000000000", entries.first.external_id
      assert_equal "B000000250", entries.last.external_id
      assert_requested :get, "https://libation.test/v1/library?limit=250&offset=0", times: 2
    end
  end

  test "accepts an older companion's legacy unpaged response to a query request" do
    VCR.turned_off do
      stub_request(:get, "https://libation.test/v1/library?limit=250&offset=0")
        .to_return(status: 200, body: {
          items: [ { asin: "B012345678", title: "Legacy" } ]
        }.to_json)

      assert_equal [ "B012345678" ], @client.library.map(&:external_id)
    end
  end

  test "starts a targeted ASIN backup and parses job" do
    VCR.turned_off do
      stub_request(:post, "https://libation.test/v1/backups/B012345678")
        .to_return(status: 202, body: { jobId: "job-1", status: "queued" }.to_json)

      job = @client.start_backup("B012345678")
      assert_equal "job-1", job.id
      assert_equal "queued", job.status
    end

    assert_raises(ArgumentError) { @client.start_backup("../invalid") }
  end

  test "parses completed job artifacts from nested result" do
    VCR.turned_off do
      stub_request(:get, "https://libation.test/v1/jobs/job-1")
        .to_return(
          status: 200,
          body: {
            id: "job-1",
            status: "succeeded",
            result: { outputPaths: [ "/data/Author/A Title.m4b" ] }
          }.to_json
        )

      job = @client.job("job-1")
      assert job.completed?
      assert_equal [ "/data/Author/A Title.m4b" ], job.artifact_paths
    end
  end

  test "rejects malformed job ids returned by the companion start boundary" do
    VCR.turned_off do
      stub_request(:post, "https://libation.test/v1/backups/B012345678")
        .to_return(status: 202, body: { jobId: "../invalid", status: "queued" }.to_json)

      assert_raises(LibationCompanionClient::ResponseError) do
        @client.start_backup("B012345678")
      end
    end
  end

  test "rejects excessive or oversized companion artifact paths" do
    excessive = Array.new(LibationCompanionClient::MAX_ARTIFACT_PATHS + 1) { |index| "/data/#{index}.m4b" }
    oversized = "/data/#{'a' * LibationCompanionClient::MAX_ARTIFACT_PATH_BYTES}.m4b"

    [ excessive, [ oversized ] ].each_with_index do |paths, index|
      VCR.turned_off do
        stub_request(:get, "https://libation.test/v1/jobs/job-#{index}")
          .to_return(status: 200, body: { id: "job-#{index}", status: "completed", artifactPaths: paths }.to_json)

        assert_raises(LibationCompanionClient::ResponseError) do
          @client.job("job-#{index}")
        end
      end
    end
  end

  test "rejects an oversized companion job error" do
    VCR.turned_off do
      stub_request(:get, "https://libation.test/v1/jobs/job-error")
        .to_return(status: 200, body: {
          id: "job-error",
          status: "failed",
          error: "x" * (LibationCompanionClient::MAX_JOB_ERROR_BYTES + 1)
        }.to_json)

      assert_raises(LibationCompanionClient::ResponseError) do
        @client.job("job-error")
      end
    end
  end
end
