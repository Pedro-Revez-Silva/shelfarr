# frozen_string_literal: true

require "openssl"

module Migration
  module Http
    module TransferCases
      GRANT_SALT = "shelfarr consumer transfer grant v1"
      JSON_TYPE = { "Content-Type" => "application/json" }.freeze
      LIVE_SCOPES = %w[library:read].to_json
      GRANT_PLACEHOLDER = "<grant>"
      LIFETIME = 86_400

      def grant_clock
        @grant_clock ||= Time.at(Time.now.to_i, 987_654, :usec).utc
      end

      def after(seconds, usec = nil)
        usec ? Time.at(grant_clock.to_i + seconds, usec, :usec).utc : grant_clock + seconds
      end

      def seed_transfer_fixtures
        alice = users.fetch("alice")
        member = User.create!(username: "xfer_member", name: "Xfer Member", password: "Synthetic-#{SecureRandom.hex(8)}-Aa1")
        @xfer_member = member
        stamp = Time.at(1_700_400_000, 777, :nsec)
        @books["xfer-removed"] = create_book("Xfer removed", :ebook, write_epub(File.join(@paths.media, "xfer-removed.epub"), "xfer-removed", stamp))
        %w[reader revoke-api scope expiry-now owner-swap ownerless destroyed string-scope].each { |name| direct_token("xfer-#{name}", alice, scopes: LIVE_SCOPES) }
        direct_token("xfer-far", alice, scopes: LIVE_SCOPES, expires_at: after(30 * LIFETIME))
        direct_token("xfer-deleted", member, scopes: LIVE_SCOPES)
        direct_token("xfer-progress-only", alice, scopes: %w[progress:write].to_json)
        direct_token("xfer-short", alice, scopes: LIVE_SCOPES, expires_at: after(7200, 500_000))
        direct_token("xfer-short-sub", alice, scopes: LIVE_SCOPES, expires_at: after(7200, 500_700))
        direct_token("xfer-parent", alice, scopes: LIVE_SCOPES)
        direct_token("xfer-child", alice, scopes: LIVE_SCOPES, replaces: @tokens.fetch("xfer-parent").id)
      end

      def transfer_scenarios
        @grants = {}
        mint_every_asset
        fetch_every_asset
        transfer_validators
        transfer_boundaries
        transfer_token_lifecycle
        transfer_adoption_lineage
        transfer_bindings
        transfer_query_grammar
        transfer_other_endpoints
        transfer_mint_failures
        transfer_removed_book
      end

      def grant_path(book, asset)
        "#{Cases::PREFIX}/library/#{book.id}/assets/#{asset.id}/transfer"
      end

      def mint_path(book, asset)
        "#{grant_path(book, asset)}_grant"
      end

      def grant_plaintext(grant)
        key = Rails.application.key_generator.generate_key(GRANT_SALT, 32)
        cipher = OpenSSL::Cipher.new("aes-256-gcm").decrypt
        cipher.key = key
        cipher.iv = Base64.urlsafe_decode64(grant[-40...-24])
        cipher.auth_tag = Base64.urlsafe_decode64(grant[-22..])
        cipher.auth_data = ""
        cipher.update(Base64.urlsafe_decode64(grant[0...-42])) + cipher.final
      end

      def mint(name, book, asset, bearer, at: grant_clock, remember: true, headers: JSON_TYPE, body: "{}", query: "", **options)
        entry = request(name, "#{mint_path(book, asset)}#{query}", bearer: bearer, method: "POST", headers: headers, body: body, at: at, track: book.id, **options)
        return entry unless entry["status"] == 201

        url = entry.dig("json", "url")
        grant = url.split("grant=").last
        entry["grant"] = { "plaintext" => grant_plaintext(grant), "length" => grant.length, "prefix" => "#{grant_path(book, asset)}?grant=" }
        entry["json"]["url"] = GRANT_PLACEHOLDER
        @grants[[ bearer, book.id, asset.id ]] = url if remember
        entry["minted_url"] = url
        entry
      end

      def grant_for(bearer, book, asset)
        @grants.fetch([ bearer, book.id, asset.id ])
      end

      def sql_step(name, statement)
        ActiveRecord::Base.with_connection { |connection| connection.execute(statement) }
        @cases << { "name" => name, "sql" => statement }
      end

      def stored_time(time)
        "'#{time.utc.strftime('%Y-%m-%d %H:%M:%S.%6N')}'"
      end

      def fetch_grant(name, url, method: "GET", at: after(60), **options)
        book_id = url[%r{/library/(\d+)/}, 1]
        request(name, url, method: method, at: at, track: book_id&.to_i, **options)
      end

      def mint_every_asset
        acquired_books.each do |book|
          listed_assets(book).each_with_index { |asset, index| mint("transfer-mint-#{book.id}-#{index}", book, asset, "xfer-reader") }
        end
      end

      def fetch_every_asset
        acquired_books.each do |book|
          listed_assets(book).each_with_index do |asset, index|
            url = grant_for("xfer-reader", book, asset)
            %w[GET HEAD].each { |method| fetch_grant("transfer-#{method.downcase}-#{book.id}-#{index}", url, method: method) }
          end
        end
      end

      def transfer_validators
        book, asset = asset_for("big-audio")
        url = grant_for("xfer-reader", book, asset)
        size = asset.size_bytes
        etag = %("#{asset.id}")
        {
          "first-byte" => "bytes=0-0", "prefix" => "bytes=0-1023", "middle" => "bytes=1000-5000", "open-ended" => "bytes=#{size - 100}-", "suffix" => "bytes=-100",
          "suffix-whole" => "bytes=-#{size + 50}", "past-end" => "bytes=#{size - 10}-#{size + 1000}", "start-at-size" => "bytes=#{size}-", "reversed" => "bytes=9-3",
          "suffix-zero" => "bytes=-0", "multiple" => "bytes=0-1,5-6", "wrong-unit" => "items=0-1", "garbage" => "bytes=abc", "blank" => " "
        }.each { |label, value| fetch_grant("transfer-range-#{label}", url, headers: { "Range" => value }) }
        fetch_grant("transfer-range-head", url, method: "HEAD", headers: { "Range" => "bytes=0-9" })
        { "match" => etag, "weak" => "W/#{etag}", "star" => "*", "list" => %("zzz", #{etag}), "other" => '"zzz"', "unquoted" => asset.id }.each do |label, value|
          fetch_grant("transfer-if-none-match-#{label}", url, headers: { "If-None-Match" => value })
        end
        fetch_grant("transfer-if-none-match-head", url, method: "HEAD", headers: { "If-None-Match" => etag })
        fetch_grant("transfer-if-none-match-beats-range", url, headers: { "If-None-Match" => etag, "Range" => "bytes=0-9" })
        fetch_grant("transfer-if-range-match", url, headers: { "Range" => "bytes=0-9", "If-Range" => etag })
        fetch_grant("transfer-if-range-other", url, headers: { "Range" => "bytes=0-9", "If-Range" => '"zzz"' })
        fetch_grant("transfer-if-range-blank", url, headers: { "Range" => "bytes=0-9", "If-Range" => "" })
        pdf_book = @books.fetch("fx-pdf")
        pdf = fixed_asset("fx-pdf", "pdf")
        fetch_grant("transfer-pdf-range", grant_for("xfer-reader", pdf_book, pdf), headers: { "Range" => "bytes=-64" })
        empty_book, empty_asset = asset_for("empty")
        mint("transfer-mint-empty", empty_book, empty_asset, "xfer-reader") unless @grants.key?([ "xfer-reader", empty_book.id, empty_asset.id ])
        fetch_grant("transfer-empty-get", grant_for("xfer-reader", empty_book, empty_asset))
        fetch_grant("transfer-empty-range", grant_for("xfer-reader", empty_book, empty_asset), headers: { "Range" => "bytes=0-0" })
      end

      def transfer_boundaries
        book, asset = asset_for("big-audio")
        mint("transfer-boundary-mint", book, asset, "xfer-reader", remember: false)
        url = @cases.last["minted_url"]
        [
          [ "issue-time", grant_clock ], [ "before-issue", after(-3600) ], [ "just-before-expiry", after(LIFETIME, 986_999) ], [ "at-expiry", after(LIFETIME, 987_000) ],
          [ "after-expiry", after(LIFETIME, 987_001) ], [ "second-after-expiry", after(LIFETIME + 1) ], [ "minute-before", after(LIFETIME - 60) ]
        ].each { |label, moment| fetch_grant("transfer-boundary-#{label}", url, at: moment) }
        %w[short short-sub far].each do |name|
          bearer = "xfer-#{name}"
          mint("transfer-lifetime-#{name}", book, asset, bearer, remember: false)
          lifetime_url = @cases.last["minted_url"]
          moments = case name
          when "short" then [ [ "before", after(7200, 499_999) ], [ "at", after(7200, 500_000) ], [ "after", after(7200, 500_001) ] ]
          when "short-sub" then [ [ "before-grant-expiry", after(7200, 499_999) ], [ "grant-expired-token-alive", after(7200, 500_300) ], [ "token-expired", after(7200, 500_700) ] ]
          else [ [ "day-minus", after(LIFETIME - 1) ], [ "day-plus", after(LIFETIME + 1) ] ]
          end
          moments.each { |label, moment| fetch_grant("transfer-lifetime-#{name}-#{label}", lifetime_url, at: moment) }
        end
      end

      def lifecycle(bearer, book, asset, name)
        mint("transfer-#{name}-mint", book, asset, bearer, remember: false)
        url = @cases.last["minted_url"]
        fetch_grant("transfer-#{name}-live", url)
        yield url
      end

      def transfer_token_lifecycle
        book, asset = asset_for("big-audio")
        id = ->(label) { @tokens.fetch(label).id }
        lifecycle("xfer-revoke-api", book, asset, "revoke-api") do |url|
          request("transfer-revoke-api-call", "#{Cases::PREFIX}/auth/revoke", method: "POST", bearer: "xfer-revoke-api", at: after(90), track: book.id)
          fetch_grant("transfer-revoke-api-after", url, at: after(120))
        end
        lifecycle("xfer-scope", book, asset, "scope") do |url|
          sql_step("transfer-scope-removed-sql", "UPDATE api_tokens SET scopes = '[\"progress:write\"]' WHERE id = #{id.call('xfer-scope')}")
          fetch_grant("transfer-scope-removed", url, at: after(90))
          sql_step("transfer-scope-restored-sql", "UPDATE api_tokens SET scopes = '[\"search:read\", \"library:read\"]' WHERE id = #{id.call('xfer-scope')}")
          fetch_grant("transfer-scope-restored", url, at: after(120))
        end
        lifecycle("xfer-string-scope", book, asset, "string-scope") do |url|
          sql_step("transfer-string-scope-sql", "UPDATE api_tokens SET scopes = '\"search:read library:read\"' WHERE id = #{id.call('xfer-string-scope')}")
          fetch_grant("transfer-string-scope-after", url, at: after(90))
          sql_step("transfer-null-element-scope-sql", "UPDATE api_tokens SET scopes = '[null, 5, \"library:read\"]' WHERE id = #{id.call('xfer-string-scope')}")
          fetch_grant("transfer-null-element-scope-after", url, at: after(100), **UNMODELLED_SCOPES)
          sql_step("transfer-null-element-without-scope-sql", "UPDATE api_tokens SET scopes = '[null, \"progress:write\"]' WHERE id = #{id.call('xfer-string-scope')}")
          fetch_grant("transfer-null-element-without-scope-after", url, at: after(110), **UNMODELLED_SCOPES)
          sql_step("transfer-unparseable-scope-sql", "UPDATE api_tokens SET scopes = '[\"\\uD800\", \"library:read\"]' WHERE id = #{id.call('xfer-string-scope')}")
          fetch_grant("transfer-unparseable-scope-after", url, at: after(115))
          sql_step("transfer-garbage-scope-sql", "UPDATE api_tokens SET scopes = 'not json' WHERE id = #{id.call('xfer-string-scope')}")
          fetch_grant("transfer-garbage-scope-after", url, at: after(120))
        end
        lifecycle("xfer-expiry-now", book, asset, "expiry-now") do |url|
          sql_step("transfer-expiry-now-sql", "UPDATE api_tokens SET expires_at = #{stored_time(after(30))} WHERE id = #{id.call('xfer-expiry-now')}")
          fetch_grant("transfer-expiry-now-after", url, at: after(90))
          sql_step("transfer-expiry-cleared-sql", "UPDATE api_tokens SET expires_at = NULL WHERE id = #{id.call('xfer-expiry-now')}")
          fetch_grant("transfer-expiry-cleared", url, at: after(120))
        end
        lifecycle("xfer-owner-swap", book, asset, "owner-swap") do |url|
          sql_step("transfer-owner-swap-sql", "UPDATE api_tokens SET user_id = #{users.fetch('bob').id} WHERE id = #{id.call('xfer-owner-swap')}")
          fetch_grant("transfer-owner-swap-after", url, at: after(90))
        end
        lifecycle("xfer-ownerless", book, asset, "ownerless") do |url|
          sql_step("transfer-ownerless-sql", "UPDATE api_tokens SET user_id = NULL WHERE id = #{id.call('xfer-ownerless')}")
          fetch_grant("transfer-ownerless-after", url, at: after(90))
        end
        lifecycle("xfer-destroyed", book, asset, "destroyed") do |url|
          sql_step("transfer-destroyed-sql", "DELETE FROM api_tokens WHERE id = #{id.call('xfer-destroyed')}")
          fetch_grant("transfer-destroyed-after", url, at: after(90))
        end
        lifecycle("xfer-deleted", book, asset, "deleted-user") do |url|
          sql_step("transfer-deleted-user-sql", "UPDATE users SET deleted_at = #{stored_time(after(30))} WHERE id = #{@xfer_member.id}")
          fetch_grant("transfer-deleted-user-after", url, at: after(90))
          request("transfer-deleted-user-mint", mint_path(book, asset), bearer: "xfer-deleted", method: "POST", headers: JSON_TYPE, body: "{}", at: after(95))
          sql_step("transfer-deleted-user-restored-sql", "UPDATE users SET deleted_at = NULL WHERE id = #{@xfer_member.id}")
          fetch_grant("transfer-deleted-user-restored", url, at: after(120))
        end
      end

      def transfer_adoption_lineage
        book, asset = asset_for("big-audio")
        parent, child = @tokens.fetch("xfer-parent").id, @tokens.fetch("xfer-child").id
        mint("transfer-lineage-parent-mint", book, asset, "xfer-parent", remember: false)
        parent_url = @cases.last["minted_url"]
        fetch_grant("transfer-lineage-parent-live", parent_url)
        mint("transfer-lineage-child-mint", book, asset, "xfer-child", remember: false, at: after(70))
        child_url = @cases.last["minted_url"]
        fetch_grant("transfer-lineage-parent-after-adoption", parent_url, at: after(80))
        fetch_grant("transfer-lineage-child-after-adoption", child_url, at: after(80))
        sql_step("transfer-lineage-unadopt-sql", "UPDATE api_tokens SET revoked_at = NULL WHERE id = #{parent}")
        sql_step("transfer-lineage-relink-sql", "UPDATE api_tokens SET replaces_api_token_id = #{parent} WHERE id = #{child}")
        fetch_grant("transfer-lineage-child-unadopted", child_url, at: after(100))
        fetch_grant("transfer-lineage-child-unadopted-head", child_url, method: "HEAD", at: after(110))
        fetch_grant("transfer-lineage-parent-unrevoked", parent_url, at: after(120))
      end

      def transfer_bindings
        book, asset = asset_for("big-audio")
        mixed, = asset_for("mixed")
        mixed_asset = listed_assets(mixed).first
        url = grant_for("xfer-reader", book, asset)
        grant = url.split("grant=").last
        fetch_grant("transfer-binding-other-asset", "#{grant_path(book, mixed_asset)}?grant=#{grant}")
        fetch_grant("transfer-binding-other-book", "#{grant_path(mixed, asset)}?grant=#{grant}")
        fetch_grant("transfer-binding-both-other", "#{grant_path(mixed, mixed_asset)}?grant=#{grant}")
        fetch_grant("transfer-binding-unknown-book", "#{Cases::PREFIX}/library/999999/assets/#{asset.id}/transfer?grant=#{grant}")
        fetch_grant("transfer-binding-bad-book-id", "#{Cases::PREFIX}/library/abc/assets/#{asset.id}/transfer?grant=#{grant}")
        fetch_grant("transfer-binding-uppercase-asset", "#{grant_path(book, asset)}?grant=#{grant}".sub(asset.id, asset.id.upcase))
        other = grant_for("xfer-reader", mixed, mixed_asset)
        fetch_grant("transfer-binding-own-other-asset", other)
        mint("transfer-binding-bob", book, asset, "bob-full", remember: false)
        fetch_grant("transfer-binding-bob-fetch", @cases.last["minted_url"])
        mint("transfer-binding-alice-read-only", book, asset, "alice-read-only", remember: false)
        fetch_grant("transfer-binding-read-only-fetch", @cases.last["minted_url"])
        mint("transfer-binding-admin", book, asset, "admin-full", remember: false)
        fetch_grant("transfer-binding-admin-fetch", @cases.last["minted_url"])
        mint("transfer-binding-string-scopes", book, asset, "member-string-scopes", remember: false)
        fetch_grant("transfer-binding-string-scopes-fetch", @cases.last["minted_url"])
      end

      UNMODELLED_SCOPES = { go: { "status" => 501, "code" => "unsupported_stored_value" } }.freeze
      MALFORMED_QUERY = { go: { "status" => 401, "code" => "invalid_grant" } }.freeze

      def transfer_query_grammar
        book, asset = asset_for("big-audio")
        url = grant_for("xfer-reader", book, asset)
        path, grant = url.split("?grant=")
        queries = {
          "absent" => nil, "empty" => "", "key-only" => "grant", "empty-value" => "grant=", "valid" => "grant=#{grant}", "trailing-ampersand" => "grant=#{grant}&",
          "leading-ampersand" => "&grant=#{grant}", "repeated" => "grant=#{grant}&grant=#{grant}", "extra-after" => "grant=#{grant}&x=1", "extra-before" => "x=1&grant=#{grant}",
          "semicolon" => "grant=#{grant};x=1", "semicolon-lead" => "x=1;grant=#{grant}", "encoded-key" => "gr%61nt=#{grant}", "upper-key" => "GRANT=#{grant}", "title-key" => "Grant=#{grant}",
          "array-key" => "grant[]=#{grant}", "hash-key" => "grant[x]=#{grant}", "nested-key" => "x[grant]=#{grant}", "double-equals" => "grant==#{grant}", "trailing-equals" => "grant=#{grant}=",
          "space-value" => "grant=+#{grant}", "plus-suffix" => "grant=#{grant}+", "encoded-space" => "grant=#{grant}%20", "encoded-char" => "grant=#{grant[0..-2]}%#{grant[-1].unpack1('H2')}",
          "short" => "grant=short", "31-chars" => "grant=#{'A' * 31}", "32-chars" => "grant=#{'A' * 32}", "2048-chars" => "grant=#{'A' * 2048}", "2049-chars" => "grant=#{'A' * 2049}",
          "truncated" => "grant=#{grant[0..-2]}", "extended" => "grant=#{grant}A", "reversed" => "grant=#{grant.reverse}", "padded" => "grant=#{grant}=", "plus-slash" => "grant=#{grant[0, 40]}+/#{grant[42..]}",
          "case-folded" => "grant=#{grant.swapcase}", "last-char-tweaked" => "grant=#{grant[0..-2]}#{grant[-1] == 'A' ? 'B' : 'A'}", "last-tag-char-lenient" => "grant=#{grant[0..-2]}#{lenient_last_char(grant)}",
          "tag-bit-flipped" => "grant=#{flip_tag(grant)}", "key-other-param" => "token=#{grant}", "other-param-first" => "x=#{grant}&grant=#{grant}", "empty-key" => "=#{grant}", "bare-token" => "#{grant}"
        }
        queries.each do |label, query|
          target = query ? "#{path}?#{query}" : path
          fetch_grant("transfer-query-#{label}", target)
        end
        %w[encoded-key repeated absent valid trailing-ampersand].each { |label| fetch_grant("transfer-query-#{label}-head", queries[label] ? "#{path}?#{queries[label]}" : path, method: "HEAD") }
        malformed = { "dangling-percent" => "grant=#{grant}%", "invalid-utf8" => "grant=#{grant}%FF", "key-invalid-utf8" => "x%FF=1&grant=#{grant}", "encoded-key-dangling" => "gr%61nt=#{grant}%", "nested-dangling" => "x[grant]=#{grant}%" }
        malformed.each do |label, query|
          fetch_grant("transfer-query-malformed-#{label}", "#{path}?#{query}", **MALFORMED_QUERY)
          fetch_grant("transfer-query-malformed-#{label}-head", "#{path}?#{query}", method: "HEAD", **MALFORMED_QUERY)
        end
        fetch_grant("transfer-query-unrelated-malformed", "#{path}?x%FF=1", **MALFORMED_QUERY)
        fetch_grant("transfer-header-bad-bearer", url, headers: { "Authorization" => "Bearer not-a-token" })
        fetch_grant("transfer-header-basic", url, headers: { "Authorization" => "Basic YWxpY2U6eA==" })
        fetch_grant("transfer-header-cookie", url, headers: { "Cookie" => "session_id=junk; _shelfarr_session=junk" })
        fetch_grant("transfer-header-bearer-without-grant", path, bearer: "alice-full")
        fetch_grant("transfer-header-bearer-bad-grant", "#{path}?grant=#{@raw.fetch('alice-full')}", bearer: "alice-full")
        fetch_grant("transfer-header-bearer-grant", "#{path}?grant=#{grant}", authorization: "Bearer #{grant}")
        fetch_grant("transfer-header-reader-formats", url, headers: { Cases::FORMATS_HEADER => "pdf" })
        fetch_grant("transfer-header-bearer-and-grant", url, bearer: "bob-full")
        %w[POST PUT PATCH DELETE OPTIONS].each do |verb|
          fetch_grant("transfer-verb-#{verb.downcase}", url, method: verb, go: { "status" => 404, "code" => "not_found" })
        end
      end

      def lenient_last_char(grant)
        alphabet = [ *"A".."Z", *"a".."z", *"0".."9", "-", "_" ]
        index = alphabet.index(grant[-1])
        alphabet[index ^ 1]
      end

      def flip_tag(grant)
        position = grant.length - 5
        alphabet = [ *"A".."Z", *"a".."z", *"0".."9", "-", "_" ]
        grant[0...position] + alphabet[alphabet.index(grant[position]) ^ 1] + grant[(position + 1)..]
      end

      def transfer_other_endpoints
        book, asset = asset_for("big-audio")
        url = grant_for("xfer-reader", book, asset)
        grant = url.split("grant=").last
        {
          "asset" => "#{asset_path(book, asset.id)}?grant=#{grant}", "publication" => "#{Cases::PREFIX}/library/#{book.id}?grant=#{grant}", "library" => "#{Cases::PREFIX}/library?grant=#{grant}",
          "progress" => "#{Cases::PREFIX}/library/#{book.id}/progress?grant=#{grant}", "me" => "#{Cases::PREFIX}/me?grant=#{grant}", "continue" => "#{Cases::PREFIX}/continue?grant=#{grant}",
          "reading-order" => "#{asset_path(book, asset.id)}/reading_order?grant=#{grant}", "grant-route" => "#{mint_path(book, asset)}?grant=#{grant}"
        }.each { |label, target| request("transfer-other-#{label}", target, at: after(60)) }
        request("transfer-other-bearer-grant-library", "#{Cases::PREFIX}/library", authorization: "Bearer #{grant}", at: after(60))
        request("transfer-other-bearer-grant-asset", asset_path(book, asset.id), authorization: "Bearer #{grant}", at: after(60))
        request("transfer-other-progress-put", "#{Cases::PREFIX}/library/#{book.id}/progress?grant=#{grant}", method: "PUT", headers: JSON_TYPE, body: "{}", at: after(60))
        request("transfer-other-reading-status-put", "#{Cases::PREFIX}/library/#{book.id}/reading_status?grant=#{grant}", method: "PUT", headers: JSON_TYPE, body: "{}", at: after(60))
      end

      def transfer_mint_failures
        book, asset = asset_for("big-audio")
        other_asset = listed_assets(asset_for("serial-audio").first).first
        path = mint_path(book, asset)
        at = after(100)
        request("transfer-mint-unauthenticated", path, method: "POST", at: at)
        request("transfer-mint-bad-token", path, method: "POST", authorization: "Bearer shf_#{'x' * 40}", at: at)
        request("transfer-mint-no-scope", path, method: "POST", bearer: "xfer-progress-only", at: at, track: book.id)
        request("transfer-mint-revoked", path, method: "POST", bearer: "alice-revoked", at: at)
        request("transfer-mint-expired", path, method: "POST", bearer: "alice-expired", at: at)
        request("transfer-mint-deleted-owner", path, method: "POST", bearer: "carol-deleted-user", at: at)
        request("transfer-mint-unknown-asset", mint_path(book, Struct.new(:id).new("0" * 64)), method: "POST", bearer: "xfer-reader", at: at, track: book.id)
        request("transfer-mint-malformed-asset", mint_path(book, Struct.new(:id).new("not-an-asset")), method: "POST", bearer: "xfer-reader", at: at)
        request("transfer-mint-uppercase-asset", mint_path(book, Struct.new(:id).new(asset.id.upcase)), method: "POST", bearer: "xfer-reader", at: at)
        request("transfer-mint-other-books-asset", mint_path(book, other_asset), method: "POST", bearer: "xfer-reader", at: at)
        request("transfer-mint-unknown-book", "#{Cases::PREFIX}/library/999999/assets/#{asset.id}/transfer_grant", method: "POST", bearer: "xfer-reader", at: at)
        request("transfer-mint-bad-book-id", "#{Cases::PREFIX}/library/#{book.id}x/assets/#{asset.id}/transfer_grant", method: "POST", bearer: "xfer-reader", at: at)
        unacquired = Book.where(file_path: [ nil ]).first
        request("transfer-mint-unacquired", "#{Cases::PREFIX}/library/#{unacquired.id}/assets/#{asset.id}/transfer_grant", method: "POST", bearer: "xfer-reader", at: at) if unacquired
        request("transfer-mint-get", path, bearer: "xfer-reader", at: at, go: { "status" => 404, "code" => "not_found" })
        request("transfer-mint-put", path, method: "PUT", bearer: "xfer-reader", at: at, go: { "status" => 404, "code" => "not_found" })
        mint("transfer-mint-no-body", book, asset, "xfer-reader", at: at, headers: {}, body: nil, remember: false)
        mint("transfer-mint-form-body", book, asset, "xfer-reader", at: at, headers: {}, body: "a=1", remember: false)
        mint("transfer-mint-json-array", book, asset, "xfer-reader", at: at, body: "[1]", remember: false)
        mint("transfer-mint-json-null", book, asset, "xfer-reader", at: at, body: "null", remember: false)
        request("transfer-mint-json-malformed", path, method: "POST", bearer: "xfer-reader", headers: JSON_TYPE, body: "{", at: at)
        request("transfer-mint-json-unauthenticated-malformed", path, method: "POST", headers: JSON_TYPE, body: "{", at: at)
        request("transfer-mint-oversized", path, method: "POST", bearer: "xfer-reader", headers: JSON_TYPE, body: "x" * (65 * 1024), at: at, go: { "status" => 413, "code" => "request_too_large" })
        request("transfer-mint-oversized-unauthenticated", path, method: "POST", headers: JSON_TYPE, body: "x" * (65 * 1024), at: at, go: { "status" => 401, "code" => "" })
        mint("transfer-mint-at-limit", book, asset, "xfer-reader", at: at, body: "{\"x\":\"#{'a' * (64 * 1024 - 8)}\"}", remember: false)
        mint("transfer-mint-with-grant-query", book, asset, "xfer-reader", at: at, query: "?grant=zzz", remember: false)
      end

      def transfer_removed_book
        book = @books.fetch("xfer-removed")
        asset = listed_assets(book).first
        mint("transfer-removed-mint", book, asset, "xfer-reader", remember: false)
        url = @cases.last["minted_url"]
        fetch_grant("transfer-removed-live", url)
        sql_step("transfer-removed-sql", "UPDATE books SET file_path = NULL WHERE id = #{book.id}")
        fetch_grant("transfer-removed-after", url, at: after(90))
        fetch_grant("transfer-removed-after-head", url, method: "HEAD", at: after(91))
        request("transfer-removed-mint-after", mint_path(book, asset), method: "POST", bearer: "xfer-reader", at: after(92))
        sql_step("transfer-removed-blank-sql", "UPDATE books SET file_path = '  ' WHERE id = #{book.id}")
        fetch_grant("transfer-removed-blank", url, at: after(100))
      end
    end
  end
end
