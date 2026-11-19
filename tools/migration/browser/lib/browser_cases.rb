# frozen_string_literal: true

require "cgi"
require "digest"
require "fileutils"
require "json"
require "securerandom"
require_relative "../../http/lib/http_cases"
require_relative "reader_media"

module Migration
  module Browser
    class Cases < Migration::Http::Cases
      PREVIEW = "/preview/api/v1"
      NOON = Time.utc(2026, 11, 15, 12, 0, 0, 123_456)
      MARKUP_DESCRIPTIONS = [
        "<p>First <b>bold</b> line &amp; entity</p><script>alert(1)</script><p>Second line</p>",
        "<img src=x onerror=alert(document.cookie)>text &lt;script&gt;alert(1)&lt;/script&gt; &copy; &#169; &#x41; &nbsp;end",
        "one<br>two<br/>three<ul><li>a</li><li>b</li></ul><h2>Heading</h2>tail",
        "<style>p{display:none}</style><a href=\"javascript:alert(1)\">link</a><form>kept<input></form><!-- gone -->after\u00a0nbsp",
        "<svg onload=alert(1)><script>1</script>s</svg><iframe src=javascript:alert(1)>fallback</iframe><textarea><b>raw</b></textarea>",
        "x < y > z &amp;amp; <unknown-tag attr=\"1\">custom</unknown-tag> \u2028 line separator"
      ].freeze
      SESSION_COLUMNS = %w[id user_id user_agent ip_address created_at updated_at].freeze
      ACCOUNT_NAMES = [
        "", "   ", "\t\n", "\u00a0\u3000", "\u0085", "\u2028", "\u200b", "\ufeff", "\u180e", "\u001c", "Zo\u00eb \u{1F4DA} \u2728", "  padded  ", "tab\tand\nline",
        "a\u0000b", "\u05e9\u05dc\u05d5\u05dd", "x" * 2000
      ].freeze
      ACCOUNT_PASSWORDS = [
        %w[Abcdefghijk1 Abcdefghijk1], [ "Aa1#{"\u00e9" * 9}", "Aa1#{"\u00e9" * 9}" ], [ "Aa1#{"\u00e9" * 5}", "Aa1#{"\u00e9" * 5}" ], [ "Aa1#{"x" * 69}", "Aa1#{"x" * 69}" ], [ "Aa1#{"x" * 70}", "Aa1#{"x" * 70}" ],
        [ "x" * 80, "x" * 80 ], %w[abc abc], %w[Ab1 zz], %w[abcdefghijk1 abcdefghijk1], %w[ABCDEFGHIJK1 ABCDEFGHIJK1], %w[Abcdefghijkl Abcdefghijkl],
        [ "Abcdefghijk1\nzz", "Abcdefghijk1\nzz" ], [ "Abcd\tefghijk1\r", "Abcd\tefghijk1\r" ], [ "Abcdefghijk1\u2028", "Abcdefghijk1\u2028" ],
        [ "Abcdefghijk\u0661", "Abcdefghijk\u0661" ], [ "\u00c0\u00c9\u00ce\u00d5\u00dc\u00c7\u00e0\u00e9\u00ee\u00f5\u00fc1", "\u00c0\u00c9\u00ce\u00d5\u00dc\u00c7\u00e0\u00e9\u00ee\u00f5\u00fc1" ],
        %w[Abcdefghijk1 Abcdefghijk2], [ "Abcdefghijk1", "" ], [ " Abcdefghijk1 ", " Abcdefghijk1 " ], [ "Aa1#{"\u{1F4DA}" * 17}", "Aa1#{"\u{1F4DA}" * 17}" ],
        [ "Aa1#{"\u{1F4DA}" * 18}", "Aa1#{"\u{1F4DA}" * 18}" ], [ "", "" ], [ "", "Abcdefghijk1" ], [ " " * 12, " " * 12 ], [ "\u3000" * 20, "\u3000" * 20 ],
        [ "Abcdefghijk1\u0000", "Abcdefghijk1\u0000" ]
      ].freeze
      USER_COLUMNS = %w[id failed_login_count last_failed_login_at last_failed_login_ip locked_until updated_at].freeze

      def initialize(paths:, bundle:)
        super
        @steps = []
        @personas = {}
        @secrets = {}
      end

      def call
        load_bundle
        reset_database
        configure_encryption
        seed_extra_library
        seed_extra_progress
        seed_fixed_layout_library
        seed_fixed_layout_progress
        seed_markup_descriptions
        seed_reader_library
        seed_people
        seed_discover_library
        seed_requests
        configure_preview
        seed_sessions
        seed_account_people
        checkpoint_and_copy
        run_browser_scenarios
        write_browser_outputs
      end

      private

      def password
        "Synthetic-#{SecureRandom.hex(10)}-Aa1"
      end

      def seed_markup_descriptions
        @markup_books = Book.acquired.where(book_type: %i[ebook audiobook]).order(:id).last(MARKUP_DESCRIPTIONS.size)
        @markup_books.zip(MARKUP_DESCRIPTIONS).each { |book, description| book.update_columns(description: description) }
      end

      def seed_reader_library
        root = File.join(@paths.media, "reader")
        stamp = Time.at(1_700_400_000, 456, :nsec)
        @reader_books = {
          "text" => create_book("Reader Text Sampler", :ebook, write_bytes(File.join(root, "Reader Text Sampler.epub"), ReaderMedia.text_epub, stamp), author: "R. Sampler"),
          "manga" => create_book("Reader Harbor Sketches", :ebook, write_bytes(File.join(root, "Reader Harbor Sketches.epub"), ReaderMedia.manga_epub, stamp + 1), author: "M. Panel"),
          "mixed" => create_book("Reader Mixed Pages", :ebook, write_bytes(File.join(root, "Reader Mixed Pages.epub"), ReaderMedia.mixed_epub, stamp + 2), author: "P. Mixed")
        }
        spoken = File.join(root, "Reader Spoken Sampler")
        [ 24, 18, 12 ].each_with_index { |seconds, index| write_bytes(File.join(spoken, "Part #{index + 1}.wav"), ReaderMedia.silent_wav(seconds), stamp + 3 + index) }
        @reader_books["audio"] = create_book("Reader Spoken Sampler", :audiobook, spoken, author: "S. Voice")
        @reader_books["pdf"] = create_book("Reader Paged Document", :ebook, write_bytes(File.join(root, "Reader Paged Document.pdf"), ReaderMedia.pdf_document(pages: 6), stamp + 6), author: "D. Pages")
        @reader_books["comic"] = create_book("Reader Harbor Panels", :comicbook, write_bytes(File.join(root, "Reader Harbor Panels.cbz"), ReaderMedia.comic_cbz, stamp + 7), author: "H. Panel")
        @reader_books["damaged"] = create_book("Reader Damaged Panels", :comicbook, write_bytes(File.join(root, "Reader Damaged Panels.cbz"), ReaderMedia.damaged_cbz, stamp + 8), author: "D. Panel")
        @reader_books["broken_pdf"] = create_book("Reader Broken Document", :ebook, write_bytes(File.join(root, "Reader Broken Document.pdf"), "%PDF-1.4\n".b + "not really a document ".b * 40, stamp + 9), author: "B. Pages")
      end

      DISCOVER_RESPONSE = File.expand_path("open_library_search.json", __dir__)
      DISCOVER_QUERY = "reader sampler"
      DISCOVER_TYPES = %w[ebook audiobook comicbook].freeze

      def seed_discover_library
        text, audio, comic = @reader_books.values_at("text", "audio", "comic")
        text.update!(open_library_work_id: "OL900001W")
        audio.update!(open_library_work_id: "OL900001W")
        comic.update!(open_library_work_id: "OL900002W", hardcover_id: "900002")
        newer_request = Book.create!(title: "Reader Text Sampler", book_type: :ebook, file_path: nil, open_library_work_id: "OL900001W")
        waiting = Book.create!(title: "Reader Waiting List", book_type: :ebook, file_path: nil, open_library_work_id: "OL900003W")
        member = @people.fetch("browser_member").fetch(:user)
        Request.create!(book: waiting, user: member, status: :pending)
        Request.create!(book: newer_request, user: member, status: :pending)
        @discover_books = { "text" => text.id, "audio" => audio.id, "comic" => comic.id, "newer_request" => newer_request.id, "waiting" => waiting.id }
      end

      def capture_discover
        body = File.read(DISCOVER_RESPONSE)
        sent = nil
        stubs = Faraday::Adapter::Test::Stubs.new
        stubs.get("/search.json") do |env|
          sent = env.params
          [ 200, { "Content-Type" => "application/json" }, body ]
        end
        OpenLibraryClient.instance_variable_set(:@connection, Faraday.new(url: OpenLibraryClient::BASE_URL) { |f| f.response :json, parser_options: { symbolize_names: false }; f.adapter :test, stubs })
        results = OpenLibraryClient.search(DISCOVER_QUERY, limit: 20)
        OpenLibraryClient.reset_connection!
        work_ids = results.map(&:work_id).compact.uniq
        lookup = Book.preload_by_work_ids(work_ids.map { |id| "openlibrary:#{id}" })
        library = work_ids.to_h do |id|
          [ id, DISCOVER_TYPES.to_h do |type|
            book = Book.find_in_lookup(lookup, [ "openlibrary:#{id}" ], book_type: type)
            [ type, book && { "book_id" => book.id, "acquired" => book.acquired? } ]
          end ]
        end
        {
          "query" => DISCOVER_QUERY, "response" => body, "rails_request" => sent,
          "rails_results" => results.map do |result|
            { "work_id" => result.work_id, "title" => result.title, "author" => result.author, "first_publish_year" => result.first_publish_year,
              "cover_id" => result.cover_id, "cover_url" => result.cover_url, "edition_count" => result.edition_count }
          end,
          "rails_library" => library, "books" => @discover_books
        }
      end

      REQUEST_FILTERS = [ {}, { "attention" => "true" }, { "status" => "active" }, { "status" => "awaiting_purchase" }, { "status" => "completed" }, { "status" => "not_found" },
                          { "status" => "failed" }, { "status" => "pending" }, { "q" => "request" }, { "q" => "R\u00c9QUEST" }, { "q" => "harbor", "status" => "active" }, { "page" => "2" } ].freeze
      FREE_TEXT_ISSUE = "Failed to connect to download client: http://admin:hunter2@10.1.2.3:8080/api"
      LISTED_ISSUE = "Search results found. Please review and select a result to download."

      def seed_requests
        member, admin, alice, outsider = @people.values_at("browser_member", "browser_admin", "alice", "browser_outsider").map { |person| person.fetch(:user) }
        made = {}
        add = lambda do |key, user, book, status, hours_ago, **columns|
          request = Request.create!(book: book, user: user, status: status)
          request.update_columns({ created_at: NOON - hours_ago.hours, updated_at: NOON - hours_ago.hours }.merge(columns))
          made[key] = request
        end
        pending_book = ->(title, type = :ebook, **extra) { Book.create!({ title: title, book_type: type, file_path: nil }.merge(extra)) }
        add.call("downloading", member, pending_book.call("Request Harbor Download", :ebook, author: "D. Loader", cover_url: "https://covers.example.test/harbor.jpg"), :downloading, 1)
        add.call("searching_attention", member, pending_book.call("Request Réquest Lanterns", :audiobook, author: "S. Seeker"), :searching, 2, attention_needed: true, issue_description: LISTED_ISSUE)
        add.call("not_found_attention", member, pending_book.call("Request Missing Atlas"), :not_found, 3, attention_needed: true, issue_description: FREE_TEXT_ISSUE, next_retry_at: NOON + 30.days, retry_count: 2)
        add.call("processing", member, pending_book.call("Request Processing Notes", :comicbook), :processing, 4)
        add.call("completed", member, @reader_books.fetch("audio"), :completed, 5, completed_at: NOON - 4.hours)
        add.call("completed_missing", member, Book.find_by!(title: "Gone Missing"), :completed, 6, completed_at: NOON - 5.hours)
        add.call("cancelled", member, pending_book.call("Request Cancelled Idea"), :failed, 7)
        add.call("store", member, pending_book.call("Request Store Offer"), :awaiting_purchase, 8)
        add.call("admin_own", admin, pending_book.call("Request Admin Own"), :pending, 9)
        add.call("other_owner", alice, pending_book.call("Request Other Owner Secret"), :downloading, 10)
        add.call("outsider", outsider, pending_book.call("Request Outsider Shelf"), :not_found, 11)
        22.times { |index| add.call("filler_#{index}", @people.fetch("bob").fetch(:user), pending_book.call(format("Queue Filler %02d", index)), :pending, 12 + index) }
        Download.create!(request: made["downloading"], status: :downloading, progress: 37, name: "Harbor.Download.RELEASE-GROUP", download_path: "/downloads/private/harbor", external_id: "client-hash-1")
        Download.create!(request: made["downloading"], status: :failed, progress: 90, name: "Harbor.Older.RELEASE-GROUP", external_id: "client-hash-0")
        Download.create!(request: made["other_owner"], status: :downloading, progress: 64, name: "Other.Owner.RELEASE")
        Download.create!(request: made["completed"], status: :completed, progress: 100, name: "Spoken.Sampler.RELEASE")
        @requests = made
      end

      def rails_request_page(cookie, query)
        session = ActionDispatch::Integration::Session.new(Rails.application)
        session.host! "www.example.com"
        path = query.empty? ? "/requests" : "/requests?#{URI.encode_www_form(query)}"
        travel_to(NOON, with_usec: true) { session.get path, headers: { "Cookie" => "session_id=#{cookie}", "Accept" => "text/html" } }
        raise "Rails answered #{session.response.status} for #{path}" unless session.response.status == 200

        page = Nokogiri::HTML(session.response.body)
        cards = page.css("[data-request-card-header]").map do |header|
          card = header.ancestors("div.bg-gray-900").first
          { "title" => header.at_css("h3").text.strip, "id" => card.at_css("a[href^='/requests/']")["href"].split("/").last.to_i,
            "labels" => header.css("span.inline-flex").map { |span| span.text.squish },
            "requested_by" => card.css("span").map(&:text).map(&:squish).find { |text| text.start_with?("Requested by ") } }
        end
        filters = page.css("nav[aria-label='Request filters'] a").map { |link| { "label" => link.text.squish, "current" => link["aria-current"] == "page" } }
        { "query" => query, "cards" => cards, "filters" => filters, "pagination" => page.css("div.mt-6 p").map { |paragraph| paragraph.text.squish }.first }
      end

      def rails_request_status(cookie, id)
        session = ActionDispatch::Integration::Session.new(Rails.application)
        session.host! "www.example.com"
        travel_to(NOON, with_usec: true) { session.get "/requests/#{id}", headers: { "Cookie" => "session_id=#{cookie}", "Accept" => "text/html" } }
        session.response.status
      end

      def capture_requests
        cookies = %w[browser_member browser_admin].to_h do |name|
          row = Session.create!(user: @people.fetch(name).fetch(:user), created_at: NOON - 1.minute, updated_at: NOON - 1.minute, ip_address: "127.0.0.1")
          [ name, session_cookie(row, expires: NOON + 30.days) ]
        end
        member_requests = Request.for_user(@people.fetch("browser_member").fetch(:user)).includes(:book).order(updated_at: :desc, id: :desc).to_a
        {
          "ids" => @requests.transform_values(&:id),
          "issues" => { "listed" => LISTED_ISSUE, "free_text" => FREE_TEXT_ISSUE },
          "rails_pages" => cookies.to_h { |name, cookie| [ name, REQUEST_FILTERS.map { |query| rails_request_page(cookie, query) } ] },
          "rails_show_status" => cookies.to_h { |name, cookie| [ name, @requests.transform_values { |request| rails_request_status(cookie, request.id) } ] },
          "rails_native_view" => travel_to(NOON, with_usec: true) { Consumer::RequestView.many(member_requests) }
        }
      end

      def seed_people
        credentials = JSON.parse(File.read(File.join(@bundle, "secrets", "credentials.json"))).fetch("users")
        @people = {}
        %w[alice bob carol].each { |name| @people[name] = { user: users.fetch(name), password: credentials.fetch(name).fetch("password") } }
        {
          "browser_admin" => { role: :admin }, "browser_member" => {}, "browser_oidc" => { oidc_provider: "synthetic", oidc_uid: SecureRandom.hex(8) },
          "browser_outsider" => {}, "browser_lockable" => {}, "browser_account" => {}, "browser_legacy" => {}
        }.each do |name, extra|
          secret = password
          @people[name] = { user: User.create!({ username: name, name: name.tr("_", " ").capitalize, password: secret }.merge(extra)), password: secret }
        end
        @people.each { |name, person| @secrets[name] = person.fetch(:password) }
      end

      def configure_preview
        allowed = @people.except("browser_outsider").values.map { |person| person[:user].id }
        @allowed = allowed.sort.join(",")
        ENV[WebPreview::Access::VARIABLE] = @allowed
      end

      def session_cookie(row, expires:)
        jar = ActionDispatch::TestRequest.create.cookie_jar
        jar.signed[:session_id] = { value: row.id, expires: expires }
        CGI.escape(jar[:session_id])
      end

      def make_session(name, user, created_at:, cookie_expires: created_at + 30.days)
        row = Session.create!(user: user, created_at: created_at, updated_at: created_at, ip_address: "127.0.0.1")
        @personas[name] = { "cookie" => session_cookie(row, expires: cookie_expires), "user_id" => user.id, "session_id" => row.id }
      end

      def rails_login(name, username)
        session = ActionDispatch::Integration::Session.new(Rails.application)
        travel_to(NOON, with_usec: true) { session.post "/session", params: { username: username, password: @people.fetch(username).fetch(:password) } }
        raw = session.response.headers["set-cookie"].to_s[/session_id=([^;]+)/, 1]
        @personas[name] = { "cookie" => raw, "user_id" => @people.fetch(username).fetch(:user).id, "session_id" => Session.maximum(:id) }
      end

      def database_rows(table, columns, where: nil)
        ActiveRecord::Base.with_connection do |connection|
          selected = columns.map { |column| "CAST(#{table}.#{column} AS TEXT) AS #{column}" }.join(", ")
          connection.select_all("SELECT #{selected} FROM #{table} #{where} ORDER BY #{table}.id").to_a
        end
      end

      def browse(name, path, persona: nil, method: "GET", account: :persona, headers: {}, body: nil, at: nil, go: nil, origin_check: false)
        sent = { "Accept" => "application/json" }.merge(headers)
        user_id = persona && @personas.fetch(persona).fetch("user_id")
        sent["Cookie"] = "session_id=#{@personas.fetch(persona).fetch('cookie')}" if persona && !headers.key?("Cookie")
        sent["X-Shelfarr-Account"] = account == :persona ? user_id.to_s : account.to_s if account && (account != :persona || user_id)
        session = ActionDispatch::Integration::Session.new(Rails.application)
        session.host! "www.example.com"
        perform = -> { session.process(method.downcase.to_sym, path, params: body&.to_json, headers: body ? sent.merge("Content-Type" => "application/json") : sent) }
        at ||= NOON
        travel_to(at, with_usec: true, &perform)
        response = session.response
        text = response.body.to_s
        clears = Array(response.headers["set-cookie"]).join("\n").match?(/session_id=;/)
        entry = { "kind" => "request", "name" => name, "persona" => persona, "method" => method, "path" => path, "headers" => sent.except("Cookie", "Accept"), "body" => body,
                  "at" => at.utc.iso8601(6), "status" => response.status, "response_headers" => normalized(response.headers), "clears_session_cookie" => clears }
        entry["json"] = JSON.parse(text) if response.media_type == "application/json" && !text.empty?
        entry["go"] = go if go
        entry["unauthenticated_go_difference"] = true if origin_check
        @steps << entry
        entry
      end

      def setting_step(name, key, value)
        SettingsService.set(key, value)
        row = Setting.find_by!(key: key.to_s)
        @steps << { "kind" => "setting", "name" => name, "key" => row.key, "value" => row.value, "value_type" => row.value_type }
      end

      def login_step(name, username, at:, password_override: nil, go: nil, submitted: nil)
        user = @people.fetch(username).fetch(:user)
        before = Session.count
        session = ActionDispatch::Integration::Session.new(Rails.application)
        secret = password_override || @people.fetch(username).fetch(:password)
        travel_to(at, with_usec: true) { session.post "/session", params: { username: submitted || username, password: secret } }
        created = Session.count - before
        entry = { "kind" => "login", "name" => name, "username" => submitted || username, "password_of" => username, "wrong_password" => !password_override.nil?, "at" => at.utc.iso8601(6), "rails_location" => session.response.location,
                  "session_created" => created.positive?, "go" => go, "users_after" => database_rows("users", USER_COLUMNS, where: "WHERE id = #{user.id}"),
                  "sessions_after" => database_rows("sessions", SESSION_COLUMNS) }
        @steps << entry
      end

      def logout_step(name, persona)
        session = ActionDispatch::Integration::Session.new(Rails.application)
        session.delete "/session", headers: { "Cookie" => "session_id=#{@personas.fetch(persona).fetch('cookie')}" }
        @steps << { "kind" => "logout", "name" => name, "persona" => persona, "status" => session.response.status, "sessions_after" => database_rows("sessions", SESSION_COLUMNS) }
      end

      def seed_account_people
        legacy = @people.fetch("browser_legacy")
        digest = BCrypt::Password.create(legacy.fetch(:password), cost: 10).to_s.sub(/\A\$2a\$/, "$2y$")
        legacy.fetch(:user).update_columns(password_digest: digest)
        raise "Rails cannot read the legacy digest" unless User.find(legacy.fetch(:user).id).authenticate(legacy.fetch(:password))
        account = @people.fetch("browser_account").fetch(:user)
        make_session("account-elsewhere", account, created_at: NOON - 2.minutes)
        make_session("account-elsewhere-b", account, created_at: NOON - 1.minute)
        make_session("legacy-elsewhere", legacy.fetch(:user), created_at: NOON - 1.minute)
        issue("account-app", account, %w[library:read progress:write])
        issue("legacy-app", legacy.fetch(:user), %w[library:read])
        @account = { "rules" => account_rules, "production_bcrypt_cost" => BCrypt::Engine::DEFAULT_COST }
      end

      def rails_errors(user_id, attributes)
        user = User.find(user_id)
        user.assign_attributes(attributes)
        user.valid? ? {} : user.errors.to_hash.transform_keys(&:to_s)
      rescue ArgumentError
        "raises"
      end

      def account_rules
        member = @people.fetch("browser_account").fetch(:user).id
        oidc = @people.fetch("browser_oidc").fetch(:user).id
        names = ACCOUNT_NAMES.map { |name| { "kind" => "name", "name" => name, "rails" => rails_errors(member, name: name) } }
        passwords = ACCOUNT_PASSWORDS.flat_map do |password, confirmation|
          [ [ member, false ], [ oidc, true ] ].map do |user_id, linked|
            { "kind" => "password", "password" => password, "confirmation" => confirmation, "oidc" => linked,
              "rails" => rails_errors(user_id, password: password, password_confirmation: confirmation) }
          end
        end
        names + passwords
      end

      def account_rails_session(person)
        session = ActionDispatch::Integration::Session.new(Rails.application)
        session.host! "www.example.com"
        travel_to(NOON, with_usec: true) { session.post "/session", params: { username: person.fetch(:user).username, password: person.fetch(:password) } }
        raise "Rails did not sign the account persona in" unless session.response.location == "http://www.example.com/"
        session
      end

      def account_scenarios
        person = @people.fetch("browser_account")
        user = person.fetch(:user)
        rails = account_rails_session(person)
        current = Session.where(user_id: user.id).maximum(:id)
        others = Session.where.not(user_id: user.id).order(:id).pluck(:id)
        tokens = token_state
        travel_to(NOON + 1.second, with_usec: true) { rails.patch "/profile", params: { user: { name: "   " } } }
        blank_status = rails.response.status
        travel_to(NOON + 2.seconds, with_usec: true) { rails.patch "/profile", params: { user: { name: "Zo\u00eb \u{1F4DA}" } } }
        renamed = User.find(user.id).name
        digest = User.find(user.id).password_digest
        changed = "Rails-Changed-#{SecureRandom.hex(6)}-Aa1"
        travel_to(NOON + 3.seconds, with_usec: true) do
          rails.patch "/profile/update_password", params: { current_password: "Wrong-#{SecureRandom.hex(4)}-Zz9", user: { password: changed, password_confirmation: changed } }
        end
        wrong = { "status" => rails.response.status, "says_incorrect" => rails.response.body.include?("Current password is incorrect"), "digest_kept" => User.find(user.id).password_digest == digest }
        travel_to(NOON + 4.seconds, with_usec: true) do
          rails.patch "/profile/update_password", params: { current_password: person.fetch(:password), user: { password: changed, password_confirmation: changed } }
        end
        stored = User.find(user.id)
        @account["rails_effects"] = {
          "blank_name_status" => blank_status, "renamed" => renamed, "wrong_current" => wrong, "change_status" => rails.response.status,
          "own_sessions_after" => Session.where(user_id: user.id).order(:id).pluck(:id) == [ current ],
          "other_sessions_kept" => Session.where.not(user_id: user.id).order(:id).pluck(:id) == others,
          "tokens_unchanged" => token_state == tokens, "new_password_authenticates" => stored.authenticate(changed).present?,
          "updated_at" => database_rows("users", %w[updated_at], where: "WHERE id = #{user.id}").first.fetch("updated_at")
        }
      end

      def seed_sessions
        fresh = NOON - 3.minutes
        make_session("alice", @people["alice"][:user], created_at: fresh)
        make_session("bob", @people["bob"][:user], created_at: fresh)
        make_session("admin", @people["browser_admin"][:user], created_at: fresh)
        make_session("member", @people["browser_member"][:user], created_at: fresh)
        make_session("outsider", @people["browser_outsider"][:user], created_at: fresh)
        make_session("deleted-user", @people["carol"][:user], created_at: fresh)
        rails_login("login-member", "browser_member")
        rails_login("login-admin", "browser_admin")
        make_session("short-envelope", @people["alice"][:user], created_at: fresh, cookie_expires: NOON + 90.seconds)
        jar = ActionDispatch::TestRequest.create.cookie_jar
        jar.signed[:other_cookie] = { value: Session.maximum(:id), expires: NOON + 30.days }
        @personas["wrong-purpose"] = { "cookie" => CGI.escape(jar[:other_cookie]), "user_id" => @people["alice"][:user].id, "session_id" => nil }
        @personas["unknown-session"] = { "cookie" => session_cookie(Struct.new(:id).new(987_654_321), expires: NOON + 30.days), "user_id" => @people["alice"][:user].id, "session_id" => nil }
        user = @people["browser_member"][:user]
        later = NOON + 31.days
        {
          "age-just-inside" => NOON - 30.days + 5.seconds, "age-just-outside" => NOON - 30.days - 1.second, "age-way-outside" => NOON - 90.days,
          "age-exact" => NOON - 30.days, "age-exact-minus-1us" => NOON - 30.days - Rational(1, 1_000_000), "age-8-days" => NOON - 8.days, "age-8-days-b" => NOON - 8.days,
          "age-6-days" => NOON - 6.days
        }.each { |name, created_at| make_session(name, user, created_at: created_at, cookie_expires: later) }
      end

      def run_browser_scenarios
        data_scenarios
        envelope_and_age_scenarios
        mutation_scenarios
        fixed_layout_browser_scenarios
        login_scenarios
        logout_scenarios
        @rails_final = { "sessions" => database_rows("sessions", SESSION_COLUMNS), "users" => database_rows("users", USER_COLUMNS) }
        account_scenarios
      end

      def data_scenarios
        browse("anonymous-session", "#{PREVIEW}/session", account: nil)
        browse("anonymous-library", "#{PREVIEW}/library", account: "1")
        %w[alice bob admin member login-member login-admin].each do |persona|
          %w[GET HEAD].each { |method| browse("#{persona}-session-#{method.downcase}", "#{PREVIEW}/session", persona: persona, method: method) }
          browse("#{persona}-library", "#{PREVIEW}/library", persona: persona)
          browse("#{persona}-continue", "#{PREVIEW}/continue", persona: persona)
        end
        browse("alice-library-audio", "#{PREVIEW}/library?type=audiobook&limit=3", persona: "alice")
        browse("alice-library-title", "#{PREVIEW}/library?sort=title&limit=7", persona: "alice")
        browse("alice-library-query", "#{PREVIEW}/library?q=quiet", persona: "alice")
        browse("alice-library-status", "#{PREVIEW}/library?status=in_progress", persona: "alice")
        browse("alice-library-bad", "#{PREVIEW}/library?type=film", persona: "alice")
        browse("alice-continue-audio", "#{PREVIEW}/continue?type=audiobook", persona: "alice")
        cursor = nil
        5.times do |page|
          entry = browse("bob-page-#{page + 1}", "#{PREVIEW}/library?limit=6#{cursor ? "&cursor=#{CGI.escape(cursor)}" : ''}", persona: "bob")
          cursor = entry.dig("json", "next_cursor")
          break unless cursor
        end
        acquired = Book.acquired.order(:id).to_a
        acquired.first(6).each { |book| browse("alice-detail-#{book.id}", "#{PREVIEW}/library/#{book.id}", persona: "alice") }
        acquired.last(3).each { |book| browse("bob-detail-#{book.id}", "#{PREVIEW}/library/#{book.id}", persona: "bob") }
        @markup_books.each { |book| browse("markup-detail-#{book.id}", "#{PREVIEW}/library/#{book.id}", persona: "alice") }
        %w[0 01 999999 abc 9223372036854775808].each { |id| browse("detail-id-#{id}", "#{PREVIEW}/library/#{id}", persona: "alice") }
        unacquired = Book.where(file_path: nil).first
        browse("detail-unacquired", "#{PREVIEW}/library/#{unacquired.id}", persona: "alice") if unacquired
        browse("outsider-session", "#{PREVIEW}/session", persona: "outsider")
        browse("outsider-library", "#{PREVIEW}/library", persona: "outsider")
        browse("deleted-user-session", "#{PREVIEW}/session", persona: "deleted-user")
        browse("deleted-user-again", "#{PREVIEW}/session", persona: "deleted-user")
        browse("wrong-purpose-session", "#{PREVIEW}/session", persona: "wrong-purpose")
        browse("unknown-session-row", "#{PREVIEW}/session", persona: "unknown-session")
        browse("account-missing", "#{PREVIEW}/session", persona: "alice", account: nil)
        browse("account-wrong", "#{PREVIEW}/session", persona: "alice", account: "2")
        browse("account-zero-padded", "#{PREVIEW}/session", persona: "alice", account: "0#{@personas['alice']['user_id']}")
        browse("bearer-is-not-a-session", "#{PREVIEW}/session", account: "1", headers: { "Authorization" => "Bearer #{@raw.fetch('alice-full')}" })
      end

      def envelope_and_age_scenarios
        browse("short-envelope-valid", "#{PREVIEW}/session", persona: "short-envelope")
        browse("short-envelope-expired", "#{PREVIEW}/session", persona: "short-envelope", at: NOON + 120.seconds)
        %w[age-just-inside age-just-outside age-way-outside age-exact age-exact-minus-1us].each { |name| browse(name, "#{PREVIEW}/session", persona: name) }
        browse("age-just-inside-later", "#{PREVIEW}/session", persona: "age-just-inside", at: NOON + 10.seconds)
        setting_step("custom-max-age", :session_max_age_days, 7)
        browse("custom-age-8-days", "#{PREVIEW}/session", persona: "age-8-days")
        browse("custom-age-6-days", "#{PREVIEW}/session", persona: "age-6-days")
        setting_step("default-max-age-restored", :session_max_age_days, 30)
        browse("default-age-8-days", "#{PREVIEW}/session", persona: "age-8-days-b")
      end

      def mutation_scenarios
        books = Book.acquired.where(book_type: %i[ebook audiobook]).order(:id).to_a
        epub = books.find(&:ebook?)
        audio = books.find(&:audiobook?)
        path = ->(book) { "#{PREVIEW}/library/#{book.id}/reading_status" }
        browse("status-alice-finished", path.call(epub), persona: "alice", method: "PUT", body: { "status" => "finished" })
        browse("status-alice-after", "#{PREVIEW}/library/#{epub.id}", persona: "alice")
        browse("status-alice-in-library", "#{PREVIEW}/library?status=finished", persona: "alice")
        browse("status-bob-isolated", "#{PREVIEW}/library/#{epub.id}", persona: "bob")
        browse("status-alice-unread-keeps-place", path.call(audio), persona: "alice", method: "PUT", body: { "status" => "unread" })
        browse("status-alice-in-progress", path.call(audio), persona: "alice", method: "PUT", body: { "status" => "in_progress" })
        browse("status-repeat", path.call(audio), persona: "alice", method: "PUT", body: { "status" => "in_progress" })
        browse("status-continue-after", "#{PREVIEW}/continue", persona: "alice")
        %w[done FINISHED].each { |value| browse("status-invalid-#{value}", path.call(epub), persona: "alice", method: "PUT", body: { "status" => value }) }
        browse("status-not-a-string", path.call(epub), persona: "alice", method: "PUT", body: { "status" => 1 })
        browse("status-missing", path.call(epub), persona: "alice", method: "PUT", body: {})
        browse("status-no-book", "#{PREVIEW}/library/999999/reading_status", persona: "alice", method: "PUT", body: { "status" => "finished" })
        browse("status-account-changed", path.call(epub), persona: "alice", method: "PUT", account: "999", body: { "status" => "finished" })
        browse("status-signed-out", path.call(epub), method: "PUT", account: "1", body: { "status" => "finished" })
        browse("status-outsider", path.call(epub), persona: "outsider", method: "PUT", body: { "status" => "finished" })
        browse("status-expired-session", path.call(epub), persona: "short-envelope", method: "PUT", at: NOON + 120.seconds, body: { "status" => "finished" })
        browse("status-member", path.call(epub), persona: "member", method: "PUT", body: { "status" => "in_progress" })
        browse("status-member-after", "#{PREVIEW}/library", persona: "member")
      end

      def fixed_layout_browser_scenarios
        %w[alice bob].each do |persona|
          browse("#{persona}-fx-library-wide", "#{PREVIEW}/library?limit=50", persona: persona)
          browse("#{persona}-fx-library-title", "#{PREVIEW}/library?sort=title&q=fx&limit=50", persona: persona)
          browse("#{persona}-fx-library-ebook", "#{PREVIEW}/library?type=ebook&q=fx&limit=50", persona: persona)
          %w[unread in_progress finished].each { |status| browse("#{persona}-fx-library-#{status}", "#{PREVIEW}/library?status=#{status}&limit=50", persona: persona) }
          browse("#{persona}-fx-continue", "#{PREVIEW}/continue", persona: persona)
          browse("#{persona}-fx-continue-ebook", "#{PREVIEW}/continue?type=ebook", persona: persona)
          cursor = nil
          6.times do |page|
            entry = browse("#{persona}-fx-page-#{page + 1}", "#{PREVIEW}/library?limit=4&sort=title&q=fx#{cursor ? "&cursor=#{CGI.escape(cursor)}" : ''}", persona: persona)
            cursor = entry.dig("json", "next_cursor")
            break unless cursor
          end
          (FIXED_KEYS + %w[fx-broken fx-missing-comic fx-pdf-early fx-pdf-empty comic-epub]).each { |key| browse("#{persona}-fx-detail-#{key}", "#{PREVIEW}/library/#{@books.fetch(key).id}", persona: persona) }
        end
        %w[fx-pdf fx-comic fx-comic-ebook fx-pdf-comic fx-series fx-missing-comic].each_with_index do |key, index|
          path = "#{PREVIEW}/library/#{@books.fetch(key).id}/reading_status"
          %w[finished in_progress unread].each_with_index do |status, position|
            browse("fx-status-#{key}-#{status}", path, persona: index.even? ? "alice" : "bob", method: "PUT", body: { "status" => status }, at: NOON + position)
          end
          browse("fx-status-#{key}-after", "#{PREVIEW}/library/#{@books.fetch(key).id}", persona: index.even? ? "alice" : "bob")
        end
        browse("fx-status-invalid-comic", "#{PREVIEW}/library/#{@books.fetch('fx-comic').id}/reading_status", persona: "alice", method: "PUT", body: { "status" => "done" })
        browse("fx-library-after-status", "#{PREVIEW}/library?limit=50&q=fx", persona: "alice")
        browse("fx-continue-after-status", "#{PREVIEW}/continue", persona: "alice")
      end

      def login_scenarios
        at = ->(seconds) { NOON + seconds }
        refused_mfa = { "status" => 501, "code" => "mfa_not_supported" }
        login_step("login-clean", "browser_lockable", at: at.call(0))
        5.times { |index| login_step("login-wrong-#{index + 1}", "browser_lockable", at: at.call(10 + index), password_override: "Wrong-#{SecureRandom.hex(4)}-Zz9") }
        login_step("login-while-locked", "browser_lockable", at: at.call(60))
        login_step("login-after-lock", "browser_lockable", at: at.call(15 * 60 + 20))
        login_step("login-wrong-password-member", "browser_member", at: at.call(15 * 60 + 35), password_override: "Wrong-#{SecureRandom.hex(4)}-Zz9")
        login_step("login-unknown-user", "browser_member", at: at.call(15 * 60 + 40), password_override: "Wrong-#{SecureRandom.hex(4)}-Zz9", submitted: "nobody_here")
        login_step("login-padded-uppercase-username", "browser_member", at: at.call(15 * 60 + 45), submitted: "  BROWSER_MEMBER ")
        login_step("login-second-factor", "alice", at: at.call(15 * 60 + 50), go: refused_mfa)
        login_step("login-oidc-account", "browser_oidc", at: at.call(15 * 60 + 60), go: { "status" => 501, "code" => "oidc_account_not_supported" })
      end

      def logout_scenarios
        logout_step("logout-login-member", "login-member")
        browse("after-logout", "#{PREVIEW}/session", persona: "login-member")
      end

      def write_browser_outputs
        FileUtils.mkdir_p(File.join(@paths.out, "secrets"), mode: 0o700)
        File.write(File.join(@paths.out, "secrets", "secret_key_base"), ENV.fetch("SECRET_KEY_BASE"), perm: 0o600)
        File.write(File.join(@paths.out, "secrets", "personas.json"), JSON.pretty_generate("personas" => @personas, "passwords" => @secrets), perm: 0o600)
        document = { "format" => 1, "bundle_media_root" => @bundle_media, "extra_media_root" => @paths.media, "database" => "db/pre-scenario.sqlite3", "server_version" => Consumer::ServerInfo.server_version,
                     "schema_revision" => @manifest.dig("schema", "revision"), "origin" => @manifest.fetch("origin"), "preview_user_ids" => @allowed, "rails_final" => @rails_final,
                     "reading_rows_after" => reading_rows, "users" => @people.transform_values { |person| person[:user].id },
                     "reader_books" => @reader_books.transform_values(&:id), "account" => @account, "discover" => capture_discover, "requests" => capture_requests, "steps" => @steps }
        File.write(File.join(@paths.out, "cases.json"), JSON.pretty_generate(document), perm: 0o600)
        ActiveRecord::Base.connection_handler.clear_all_connections!
        Dir.glob("#{@paths.primary_db}*").each { |file| FileUtils.rm_f(file) }
        FileUtils.rm_rf(File.join(@paths.out, "scratch"))
      end
    end
  end
end
