# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"
require_relative "../../http/lib/http_cases"

module Migration
  module Pairing
    class Cases < Migration::Http::Cases
      NOON = Time.utc(2026, 11, 15, 12, 0, 0, 123_456)
      CONNECT = "/consumer/connect"
      FLOW_SPACING = 5 * 60
      SECRET_FIELDS = %w[device_code user_code access_token].freeze
      BUNDLE = "library:read progress:write search:read requests:read requests:write"

      def initialize(paths:, bundle:)
        super
        @steps = []
        @vars = {}
        @digest_names = {}
        @people = {}
        @web = {}
        @flow = 0
        @previous = { "grants" => {}, "tokens" => {} }
      end

      def call
        load_bundle
        reset_database
        configure_encryption
        share_rate_limit_store
        seed_people
        seed_connections
        checkpoint_and_copy
        @session = ActionDispatch::Integration::Session.new(Rails.application)
        @session.host! "www.example.com"
        sign_in_people
        @previous = snapshot
        run_scenarios
        write_pairing_outputs
      end

      private

      class WindowStore < ActiveSupport::Cache::NullStore
        attr_accessor :enabled

        def initialize
          super
          @counters = {}
        end

        def increment(name, amount = 1, options = nil)
          return nil unless enabled

          within = (options || {}).fetch(:expires_in)
          key = name.to_s
          entry = @counters[key]
          entry = nil if entry && entry[:expires_at] <= Time.now.to_r
          entry ||= { count: 0, expires_at: Time.now.to_r + within.to_r }
          entry[:count] += amount
          @counters[key] = entry
          entry[:count]
        end
      end

      def share_rate_limit_store
        @limits = WindowStore.new
        ActionController::API.cache_store = @limits
        ActionController::Base.cache_store = @limits
        Rails.cache = @limits
        Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false
      end

      def secret
        "Synthetic-#{SecureRandom.hex(10)}-Aa1"
      end

      def seed_people
        { "pair_one" => {}, "pair_two" => {}, "pair_admin" => { role: :admin } }.each do |username, extra|
          password = secret
          @people[username] = { user: User.create!({ username: username, name: username.tr("_", " ").capitalize, password: password }.merge(extra)), password: password }
        end
      end

      def person(name)
        @people.fetch(name).fetch(:user)
      end

      def seed_token(label, user, scopes: %w[library:read progress:write], key: :new, **columns)
        raw = "shf_#{SecureRandom.alphanumeric(40)}"
        connection_key = key == :new ? SecureRandom.uuid : key
        token = APIToken.create!(name: label, user: user, scopes: scopes.to_json, token_digest: APIToken.digest(raw), token_prefix: raw.first(12), connection_key: connection_key,
          issued_via: APIToken::CONSUMER_DEVICE, created_at: Time.utc(2026, 11, 1), updated_at: Time.utc(2026, 11, 1), **columns)
        @raw["tok:#{label}"] = raw
        @digest_names[APIToken.digest(raw)] = "tok:#{label}"
        token
      end

      def seed_connections
        @raw = {}
        one, two, admin = person("pair_one"), person("pair_two"), person("pair_admin")
        shared = SecureRandom.uuid
        seed_token("one-fresh", one, key: shared)
        seed_token("one-second", one, key: shared)
        seed_token("one-other-key", one)
        seed_token("two-same-key", two, key: shared)
        seed_token("two-own", two)
        seed_token("legacy-a", one, key: nil)
        seed_token("legacy-b", one, key: nil)
        seed_token("legacy-ws", one, key: "  ")
        seed_token("legacy-ws-two", one, key: "  ")
        seed_token("progress-only", one, scopes: %w[progress:write])
        seed_token("revoked", one, revoked_at: Time.utc(2026, 11, 10))
        seed_token("expired", one, expires_at: Time.utc(2026, 11, 10))
        seed_token("stale-revoke", one)
        seed_token("stale-expire", one)
        seed_token("admin-conn", admin)
        seed_token("carol", User.find_by!(username: "carol"))
        seed_token("ownerless", nil)
        orphan = seed_token("orphan", one)
        ActiveRecord::Base.with_connection do |connection|
          connection.execute("PRAGMA foreign_keys = OFF")
          connection.execute("UPDATE api_tokens SET user_id = 987654 WHERE id = #{orphan.id}")
          connection.execute("PRAGMA foreign_keys = ON")
        end
      end

      def sign_in_people
        @people.each do |username, entry|
          web = ActionDispatch::Integration::Session.new(Rails.application)
          web.host! "www.example.com"
          travel_to(NOON, with_usec: true) { web.post "/session", params: { username: username, password: entry[:password] } }
          raise "sign-in failed for #{username}" unless web.response.redirect?

          @web[username] = web
        end
      end

      def flow(label)
        @flow += 1
        @flow_label = label
        @base = NOON + (@flow * FLOW_SPACING)
      end

      def at(seconds)
        @base + seconds
      end

      def iso(time)
        time.utc.iso8601(6)
      end

      def resolve(text)
        text.gsub(/\$\{([A-Za-z0-9:_-]+)(?:\|(\w+))?\}/) do
          value = @vars.fetch(Regexp.last_match(1)) { @raw.fetch(Regexp.last_match(1)) }
          case Regexp.last_match(2)
          when nil then value
          when "lower" then value.downcase
          when "nohyphen" then value.delete("-")
          when "digest" then Digest::SHA256.hexdigest(value)
          when "spaced" then value.sub("-", " ")
          else raise "unknown transform #{Regexp.last_match(2)}"
          end
        end
      end

      def resolve_deep(value)
        case value
        when String then resolve(value)
        when Array then value.map { |item| resolve_deep(item) }
        when Hash then value.transform_values { |item| resolve_deep(item) }
        else value
        end
      end

      def database_rows(sql)
        ActiveRecord::Base.with_connection { |connection| connection.select_all(sql).to_a }
      end

      def key_label(key)
        return nil if key.nil?

        @key_labels ||= {}
        @key_labels[key] ||= "key-#{@key_labels.size + 1}"
      end

          GRANT_SQL = "SELECT id, user_id, client_name, CAST(expires_at AS TEXT) AS expires_at, CAST(approved_at AS TEXT) AS approved_at, CAST(denied_at AS TEXT) AS denied_at, CAST(consumed_at AS TEXT) AS consumed_at, " \
                  "CAST(last_polled_at AS TEXT) AS last_polled_at, poll_interval, scopes, replaces_api_token_id, CAST(created_at AS TEXT) AS created_at, CAST(updated_at AS TEXT) AS updated_at, " \
                  "device_code_digest, user_code_digest FROM consumer_device_grants ORDER BY id"
      TOKEN_SQL = "SELECT id, user_id, name, scopes, token_prefix, CAST(expires_at AS TEXT) AS expires_at, issued_via, replaces_api_token_id, CAST(revoked_at AS TEXT) AS revoked_at, " \
                  "CAST(last_used_at AS TEXT) AS last_used_at, CAST(created_at AS TEXT) AS created_at, CAST(updated_at AS TEXT) AS updated_at, token_digest, connection_key FROM api_tokens ORDER BY id"

      def snapshot
        @key_labels = nil
        grants = database_rows(GRANT_SQL).map do |row|
          device = @digest_names[row.delete("device_code_digest")]
          user = @digest_names[row.delete("user_code_digest")]
          row.merge("device_var" => device, "user_var" => user)
        end
        tokens = database_rows(TOKEN_SQL).map do |row|
          digest = row.delete("token_digest")
          key = row.delete("connection_key")
          name = @digest_names[digest]
          known = name && (@raw[name] || @vars[name])
          prefix = row["token_prefix"]
          row = row.except("token_prefix") if known
          row.merge("token_var" => name, "prefix_matches" => known ? known.first(12) == prefix : nil, "connection" => key_label(key))
        end
        { "grants" => grants.to_h { |row| [ row["id"].to_s, row ] }, "tokens" => tokens.to_h { |row| [ row["id"].to_s, row ] } }
      end

      def delta
        current = snapshot
        result = %w[grants tokens].to_h do |table|
          before = @previous.fetch(table)
          after = current.fetch(table)
          [ table, { "changed" => after.reject { |id, row| before[id] == row }, "deleted" => (before.keys - after.keys).sort_by(&:to_i) } ]
        end
        @previous = current
        result
      end

      def normalize_json(json)
        return json unless json.is_a?(Hash)

        json.to_h do |key, value|
          next [ key, "<#{key}>" ] if SECRET_FIELDS.include?(key) && value.is_a?(String)

          if %w[verification_uri verification_uri_complete].include?(key) && value.is_a?(String)
            next [ key, value.sub("http://www.example.com", "<origin>").sub(/user_code=[A-Z0-9]{4}-[A-Z0-9]{4}\z/, "user_code=<user_code>") ]
          end
          [ key, value ]
        end
      end

      def register(save, json)
        return unless json.is_a?(Hash)

        save.each do |field, name|
          value = json[field]
          next unless value.is_a?(String)

          @vars[name] = value
          digest_source = field == "user_code" ? value.delete("-") : value
          @digest_names[Digest::SHA256.hexdigest(digest_source)] = name
        end
      end

      def exchange(name, method, path, auth: nil, body: nil, raw: nil, type: "application/json", at: nil, save: {}, go: nil, headers: {})
        sent = headers.dup
        sent["Authorization"] = resolve(auth) if auth
        payload = raw ? resolve(raw) : (body ? JSON.generate(resolve_deep(body)) : nil)
        sent["Content-Type"] = type if payload && type
        moment = at || @base
        travel_to(moment, with_usec: true) { @session.process(method.downcase.to_sym, path, params: payload, headers: sent) }
        response = @session.response
        text = response.body.to_s
        json = (JSON.parse(text) if response.media_type == "application/json" && !text.empty?)
        warn "#{name} #{response.status} #{text[0, 160]}" if ENV["PAIRING_TRACE"]
        register(save, json)
        entry = { "kind" => "request", "name" => name, "flow" => @flow_label, "method" => method, "path" => path, "authorization" => auth, "body" => body, "raw" => raw, "content_type" => payload ? type : nil,
                  "headers" => headers, "at" => iso(moment), "save" => save, "status" => response.status,
                  "response_headers" => normalized(response.headers).slice("cache-control", "referrer-policy", "content-type"), "body_empty" => text.empty?, "json" => normalize_json(json), "rows" => delta }
        entry["go"] = go if go
        @steps << entry
        entry
      end

      def device(name, **options)
        exchange(name, "POST", "#{PREFIX}/auth/device", **options)
      end

      def token(name, device_var, **options)
        exchange(name, "POST", "#{PREFIX}/auth/token", body: { "device_code" => "${#{device_var}}" }, **options)
      end

      def me(name, auth, **options)
        exchange(name, "GET", "#{PREFIX}/me", auth: auth, **options)
      end

      def revoke(name, auth, **options)
        exchange(name, "POST", "#{PREFIX}/auth/revoke", auth: auth, body: {}, **options)
      end

      def bearer(label)
        "Bearer ${#{label}}"
      end

      def web_step(kind, name, actor, user_code, decision: nil, at: nil)
        moment = at || @base
        web = @web.fetch(actor)
        code = resolve(user_code)
        travel_to(moment, with_usec: true) do
          if kind == "inspect"
            web.get CONNECT, params: { user_code: code }
          else
            web.post CONNECT, params: { user_code: code, decision: decision }
          end
        end
        @steps << { "kind" => kind, "name" => name, "flow" => @flow_label, "actor" => actor, "user_code" => user_code, "decision" => decision, "at" => iso(moment), "status" => web.response.status, "rows" => delta }
      end

      def inspect_code(name, actor, user_code, at: nil)
        web_step("inspect", name, actor, user_code, at: at)
      end

      def decide(name, actor, user_code, decision, at: nil)
        web_step("decide", name, actor, user_code, decision: decision, at: at)
      end

      def sql(name, statement, at: nil)
        text = resolve(statement)
        ActiveRecord::Base.with_connection { |connection| connection.execute(text) }
        @steps << { "kind" => "sql", "name" => name, "flow" => @flow_label, "statement" => statement, "at" => iso(at || @base), "rows" => delta }
      end

      def define(var, value)
        @vars[var] = value
        @digest_names[Digest::SHA256.hexdigest(value)] = var
        @steps << { "kind" => "define", "var" => var, "value" => value }
      end

      def burst(name, path, body:, count:, at: nil)
        moment = at || @base
        statuses = []
        count.times do
          travel_to(moment, with_usec: true) { @session.process(:post, path, params: JSON.generate(body), headers: { "Content-Type" => "application/json" }) }
          statuses << @session.response.status
        end
        @steps << { "kind" => "burst", "name" => name, "flow" => @flow_label, "path" => path, "body" => body, "count" => count, "at" => iso(moment), "statuses" => statuses, "limited_json" => JSON.parse(@session.response.body), "rows" => delta }
      end

      def run_scenarios
        fresh_base_flow
        denied_flow
        boundary_flow
        requesting_flow
        name_input_flow
        scope_input_flow
        body_input_flow
        upgrade_flow
        legacy_key_flow
        invalid_origin_flow
        stale_origin_flow
        revoke_edge_flow
        legacy_scope_flow
        cleanup_flow
        deleted_approver_flow
        rate_limit_flow
        @final = snapshot
        prepare_handoff
      end

      HANDOFF_AT = Time.utc(2026, 11, 16, 9, 0, 0, 250_000)

      def issue_credential(label, user, scopes: %w[library:read progress:write], replaces: nil)
        token, raw = APIToken.issue!(name: label, user: user, scopes: scopes, issued_via: APIToken::CONSUMER_DEVICE, replaces: replaces)
        @handoff[label] = raw
        token
      end

      def prepare_handoff
        @handoff = {}
        one = person("pair_one")
        travel_to(HANDOFF_AT, with_usec: true) do
          _, device, user = ConsumerDeviceGrant.issue!(client_name: "Rails pending")
          @handoff.merge!("pending_device" => device, "pending_user" => user)
          approved, device, = ConsumerDeviceGrant.issue!(client_name: "Rails approved")
          approved.decide!(actor: one, allow: true)
          @handoff["approved_device"] = device
          denied, device, = ConsumerDeviceGrant.issue!(client_name: "Rails denied")
          denied.decide!(actor: one, allow: false)
          @handoff["denied_device"] = device
          origin = issue_credential("upgrade_origin", one)
          upgrade, device, = ConsumerDeviceGrant.issue!(client_name: "Rails upgrade", scope: BUNDLE, replaces: origin)
          upgrade.decide!(actor: one, allow: true)
          @handoff["upgrade_device"] = device
          issue_credential("plain", one)
          first = issue_credential("chain_first", one)
          issue_credential("chain_second", one, replaces: first)
          family = issue_credential("family_a", one)
          issue_credential("family_b", one, replaces: family).update!(replaces_api_token_id: nil)
          _, device, = ConsumerDeviceGrant.issue!(client_name: "Rails family upgrade", scope: BUNDLE, replaces: family)
          @handoff["family_upgrade_device"] = device
        end
        ActiveRecord::Base.with_connection { |connection| connection.execute("PRAGMA wal_checkpoint(TRUNCATE)") }
        ActiveRecord::Base.connection_handler.clear_all_connections!
        FileUtils.cp(@paths.primary_db, File.join(@paths.out, "db", "handoff.sqlite3"))
      end

      def fresh_base_flow
        flow("fresh-base")
        device("device-fresh", body: { "client_name" => "  Pair App  " }, save: { "device_code" => "dev1", "user_code" => "user1" })
        token("poll-pending", "dev1", at: at(1))
        token("poll-slow-1", "dev1", at: at(2))
        token("poll-slow-2", "dev1", at: at(3))
        inspect_code("inspect-by-owner", "pair_one", "${user1}", at: at(4))
        decide("decide-allow", "pair_one", "${user1|lower}", "allow", at: at(10))
        token("poll-early-after-allow", "dev1", at: at(12))
        token("poll-issue", "dev1", at: at(50), save: { "access_token" => "tok1" })
        me("me-issued-token", bearer("tok1"), at: at(51))
        token("poll-replay", "dev1", at: at(80))
        decide("decide-after-consume", "pair_one", "${user1}", "allow", at: at(81))
      end

      def denied_flow
        flow("denied")
        device("device-denied", body: { "client_name" => "Denied App" }, save: { "device_code" => "dev2", "user_code" => "user2" })
        decide("decide-invalid-decision", "pair_one", "${user2}", "maybe", at: at(4))
        decide("decide-deny", "pair_one", "${user2|nohyphen}", "deny", at: at(5))
        token("poll-denied", "dev2", at: at(15))
        token("poll-denied-again", "dev2", at: at(30))
        decide("decide-allow-after-deny", "pair_one", "${user2}", "allow", at: at(31))
        token("poll-denied-before-expiry", "dev2", at: at(600 - Rational(1, 1_000_000)))
        token("poll-expired-after-denial", "dev2", at: at(600))
      end

      def boundary_flow
        flow("boundary")
        device("device-boundary-a", body: { "client_name" => "Boundary A" }, save: { "device_code" => "dev3a", "user_code" => "user3a" })
        device("device-boundary-b", body: { "client_name" => "Boundary B" }, save: { "device_code" => "dev3b", "user_code" => "user3b" })
        token("poll-a-pending", "dev3a", at: at(1))
        token("poll-a-pending-before-expiry", "dev3a", at: at(600 - Rational(1, 1_000_000)))
        token("poll-b-at-expiry", "dev3b", at: at(600))
        token("poll-b-after-expiry", "dev3b", at: at(601))
        decide("decide-at-expiry", "pair_one", "${user3a}", "allow", at: at(600))
        decide("decide-expired-code", "pair_one", "${user3b}", "allow", at: at(601))
        decide("decide-unknown-code", "pair_one", "BCDF-GHJK", "allow", at: at(602))
        decide("decide-malformed-code", "pair_one", "not a code", "allow", at: at(603))
        decide("decide-lookalike-code", "pair_one", "${user3a|spaced}", "deny", at: at(604))
        inspect_code("inspect-unknown", "pair_one", "BCDF-GHJK", at: at(605))
      end

      def requesting_flow
        flow("requesting")
        device("device-bundle", body: { "client_name" => "Bundle App", "scope" => "requests:write search:read library:read requests:read progress:write" }, save: { "device_code" => "dev4", "user_code" => "user4" })
        decide("decide-bundle", "pair_one", "${user4}", "allow", at: at(10))
        token("poll-bundle", "dev4", at: at(40), save: { "access_token" => "tok4" })
        me("me-bundle", bearer("tok4"), at: at(41))
        device("device-admin", body: { "client_name" => "Admin Phone", "scope" => BUNDLE }, save: { "device_code" => "dev5", "user_code" => "user5" }, at: at(50))
        decide("decide-admin", "pair_admin", "${user5}", "allow", at: at(60))
        token("poll-admin", "dev5", at: at(90), save: { "access_token" => "tok5" })
        me("me-admin-device-token", bearer("tok5"), at: at(91))
        me("me-admin-seeded-token", bearer("tok:admin-conn"), at: at(92))
      end

      def name_input_flow
        flow("name-input")
        { "missing" => {}, "empty" => { "client_name" => "" }, "spaces" => { "client_name" => "   " }, "nbsp" => { "client_name" => " " }, "tab-padded-blank" => { "client_name" => "\t\n" },
          "81-bytes" => { "client_name" => "n" * 81 }, "hash" => { "client_name" => {} }, "array" => { "client_name" => [ "a" ] }, "number" => { "client_name" => 5 },
          "null" => { "client_name" => nil } }.each_with_index { |(label, body), index| device("name-#{label}", body: body, at: at(index)) }
        { "80-bytes" => "n" * 80, "unicode-80-bytes" => "é" * 40, "unicode-82-bytes" => "é" * 41, "leading-nbsp" => " App", "padded-81-bytes" => "  #{'n' * 79}" }.each_with_index do |(label, value), index|
          device("name-#{label}", body: { "client_name" => value }, at: at(20 + index))
        end
        device("name-with-whitespace-around", body: { "client_name" => "\t App Name \n" }, at: at(40))
        device("name-before-token-check", body: { "client_name" => 5 }, auth: "Bearer shf_garbage", at: at(41))
      end

      def scope_input_flow
        flow("scope-input")
        {
          "base-pair" => "library:read progress:write", "reversed-base" => "progress:write library:read", "only-library" => "library:read", "empty" => "", "blank" => "   ", "duplicates" => "library:read library:read",
          "tabs" => "library:read\tprogress:write\n", "bundle" => BUNDLE, "bundle-extra-space" => "library:read   progress:write #{BUNDLE.split.last(3).reverse.join(' ')}",
          "partial-search" => "search:read", "partial-requests" => "requests:read requests:write", "admin" => "library:read requests:admin", "users" => "users:write", "unknown" => "nonsense",
          "nbsp" => "library:read progress:write", "nul" => "library:read\u0000progress:write", "too-long" => "a" * 201
        }.each_with_index { |(label, value), index| device("scope-#{label}", body: { "client_name" => "Scoped #{label}", "scope" => value }, at: at(index)) }
        device("scope-null", body: { "client_name" => "Scoped null", "scope" => nil }, at: at(30))
        device("scope-array", body: { "client_name" => "Scoped array", "scope" => [ "library:read" ] }, at: at(31))
      end

      def body_input_flow
        flow("body-input")
        exchange("body-malformed-json", "POST", "#{PREFIX}/auth/device", raw: '{"client_name":', go: { "status" => 400, "code" => "invalid_json" })
        exchange("body-empty-device", "POST", "#{PREFIX}/auth/device", raw: "")
        exchange("body-array-device", "POST", "#{PREFIX}/auth/device", raw: "[1]")
        exchange("body-string-device", "POST", "#{PREFIX}/auth/device", raw: '"x"')
        exchange("body-empty-token", "POST", "#{PREFIX}/auth/token", raw: "")
        exchange("body-malformed-token", "POST", "#{PREFIX}/auth/token", raw: "{", go: { "status" => 400, "code" => "invalid_json" })
        exchange("body-array-token", "POST", "#{PREFIX}/auth/token", raw: "[1]")
        exchange("body-oversized-device", "POST", "#{PREFIX}/auth/device", raw: "x" * 65_537, go: { "status" => 413, "code" => "request_too_large" })
        exchange("body-oversized-token", "POST", "#{PREFIX}/auth/token", raw: "x" * 65_537, go: { "status" => 413, "code" => "request_too_large" })
        %w[null 5 [] {} "x" true].each { |value| exchange("token-device-code-#{value}", "POST", "#{PREFIX}/auth/token", raw: %({"device_code":#{value}})) }
        exchange("token-device-code-short", "POST", "#{PREFIX}/auth/token", raw: %({"device_code":"abc"}))
        exchange("token-device-code-uppercase", "POST", "#{PREFIX}/auth/token", raw: %({"device_code":"#{'A' * 64}"}))
        exchange("token-device-code-unknown", "POST", "#{PREFIX}/auth/token", raw: %({"device_code":"#{'a' * 64}"}))
        exchange("token-device-code-newline", "POST", "#{PREFIX}/auth/token", raw: %({"device_code":"#{'a' * 64}\\n"}))
        exchange("body-duplicate-keys", "POST", "#{PREFIX}/auth/device", raw: '{"client_name":"First","client_name":"Second"}')
      end

      def upgrade_flow
        flow("upgrade")
        device("device-upgrade", auth: bearer("tok:one-fresh"), body: { "client_name" => "Upgrade App", "scope" => BUNDLE }, save: { "device_code" => "dev6", "user_code" => "user6" })
        inspect_code("inspect-other-account", "pair_two", "${user6}", at: at(2))
        decide("decide-other-account-allow", "pair_two", "${user6}", "allow", at: at(3))
        decide("decide-other-account-deny", "pair_two", "${user6}", "deny", at: at(4))
        token("poll-upgrade-pending", "dev6", at: at(5))
        decide("decide-owner-allow", "pair_one", "${user6}", "allow", at: at(10))
        token("poll-upgrade-issue", "dev6", at: at(40), save: { "access_token" => "tok6" })
        me("me-old-before-new-used", bearer("tok:one-fresh"), at: at(41))
        me("me-new-first-use", bearer("tok6"), at: at(42))
        me("me-old-after-adoption", bearer("tok:one-fresh"), at: at(43))
        me("me-new-after-adoption", bearer("tok6"), at: at(44))
        me("me-family-sibling", bearer("tok:one-second"), at: at(45))
        device("device-upgrade-from-adopted", auth: bearer("tok6"), body: { "client_name" => "Upgrade App", "scope" => BUNDLE }, save: { "device_code" => "dev7", "user_code" => "user7" }, at: at(50))
        decide("decide-second-upgrade", "pair_one", "${user7}", "allow", at: at(51))
        device("device-upgrade-pending-at-revoke", auth: bearer("tok6"), body: { "client_name" => "Upgrade App", "scope" => BUNDLE }, save: { "device_code" => "dev8", "user_code" => "user8" }, at: at(52))
        revoke("revoke-family", bearer("tok6"), at: at(60))
        token("poll-approved-after-revoke", "dev7", at: at(90))
        token("poll-pending-after-revoke", "dev8", at: at(100))
        me("me-sibling-after-revoke", bearer("tok:one-second"), at: at(101))
        me("me-other-account-same-key", bearer("tok:two-same-key"), at: at(102))
        me("me-new-after-revoke", bearer("tok6"), at: at(103))
      end

      def legacy_key_flow
        flow("legacy-key")
        device("device-legacy-upgrade", auth: bearer("tok:legacy-a"), body: { "client_name" => "Legacy App", "scope" => BUNDLE }, save: { "device_code" => "dev9", "user_code" => "user9" })
        decide("decide-legacy-upgrade", "pair_one", "${user9}", "allow", at: at(10))
        token("poll-legacy-upgrade", "dev9", at: at(40), save: { "access_token" => "tok9" })
        me("me-legacy-new", bearer("tok9"), at: at(41))
        revoke("revoke-legacy-family", bearer("tok9"), at: at(50))
        me("me-legacy-sibling", bearer("tok:legacy-b"), at: at(51))
        revoke("revoke-blank-key-token", bearer("tok:legacy-ws"), at: at(60))
        me("me-blank-key-sibling", bearer("tok:legacy-ws-two"), at: at(61))
        revoke("revoke-other-key", bearer("tok:one-other-key"), at: at(62))
        me("me-other-account-own", bearer("tok:two-own"), at: at(63))
      end

      def invalid_origin_flow
        flow("invalid-origin")
        scoped = { "client_name" => "Stale App", "scope" => BUNDLE }
        %w[revoked expired progress-only carol ownerless orphan].each_with_index do |label, index|
          device("origin-#{label}", auth: bearer("tok:#{label}"), body: scoped, at: at(index))
        end
        { "garbage" => "Bearer shf_garbage", "basic" => "Basic YTpi", "bearer-alone" => "Bearer", "bare-token" => "${tok:two-own}", "lowercase-scheme" => "bearer ${tok:two-own}" }.each_with_index do |(label, value), index|
          device("origin-#{label}", auth: value, body: scoped, at: at(10 + index))
        end
        device("origin-valid-bad-scope", auth: bearer("tok:two-own"), body: { "client_name" => "Stale App", "scope" => "requests:admin" }, at: at(20))
        device("origin-valid-other-owner", auth: bearer("tok:two-own"), body: scoped, save: { "device_code" => "dev10", "user_code" => "user10" }, at: at(21))
        decide("origin-wrong-approver", "pair_one", "${user10}", "allow", at: at(22))
        decide("origin-owner-approver", "pair_two", "${user10}", "allow", at: at(23))
        token("origin-poll-owner", "dev10", at: at(60), save: { "access_token" => "tok10" })
        device("origin-blank-header", headers: { "Authorization" => "   " }, body: { "client_name" => "Blank Header" }, at: at(30))
      end

      def stale_origin_flow
        flow("stale-origin")
        device("stale-revoked", auth: bearer("tok:stale-revoke"), body: { "client_name" => "Stale", "scope" => BUNDLE }, save: { "device_code" => "dev11", "user_code" => "user11" })
        decide("stale-revoked-allow", "pair_one", "${user11}", "allow", at: at(5))
        sql("stale-revoked-sql", "UPDATE api_tokens SET revoked_at = '2026-11-15 12:00:06' WHERE name = 'stale-revoke'", at: at(6))
        token("stale-revoked-poll", "dev11", at: at(20))
        token("stale-revoked-poll-again", "dev11", at: at(40))
        device("stale-expired", auth: bearer("tok:stale-expire"), body: { "client_name" => "Stale", "scope" => BUNDLE }, save: { "device_code" => "dev12", "user_code" => "user12" }, at: at(50))
        decide("stale-expired-allow", "pair_one", "${user12}", "allow", at: at(55))
        sql("stale-expired-sql", "UPDATE api_tokens SET expires_at = '2026-11-15 12:01:00' WHERE name = 'stale-expire'", at: at(56))
        token("stale-expired-poll", "dev12", at: at(80))
      end

      def revoke_edge_flow
        flow("revoke-edge")
        exchange("revoke-anonymous", "POST", "#{PREFIX}/auth/revoke", body: {})
        revoke("revoke-garbage", "Bearer shf_garbage")
        revoke("revoke-revoked-token", bearer("tok:revoked"))
        revoke("revoke-expired-token", bearer("tok:expired"))
        revoke("revoke-ownerless", bearer("tok:ownerless"))
        revoke("revoke-deleted-owner", bearer("tok:carol"))
        revoke("revoke-progress-only", bearer("tok:progress-only"), at: at(10))
        revoke("revoke-progress-only-again", bearer("tok:progress-only"), at: at(11))
        exchange("revoke-no-body", "POST", "#{PREFIX}/auth/revoke", auth: bearer("tok:two-own"), at: at(20))
        exchange("revoke-already", "POST", "#{PREFIX}/auth/revoke", auth: bearer("tok:two-own"), body: {}, at: at(21))
        me("me-after-revoke-edge", bearer("tok:admin-conn"), at: at(22))
      end

      def legacy_scope_flow
        flow("legacy-scopes")
        scopes = { "null" => "NULL", "empty" => "''", "spaces" => "'   '", "not-json" => "'not json'", "partial" => %q('["search:read"]'), "string" => %q('"library:read"'), "object" => %q('{"a":1}'),
                   "number-list" => "'[1]'", "nested-bundle" => %q('[["search:read","requests:read"],"requests:write"]'), "bundle-reordered" => %q('["requests:write","requests:read","search:read"]'),
                   "admin" => %q('["requests:admin"]'), "base-explicit" => %q('["progress:write","library:read"]') }
        scopes.each_with_index do |(label, value), index|
          var = "legacy-#{label}"
          define(var, SecureRandom.hex(32))
          expires = (@base + 3600).utc.strftime("%Y-%m-%d %H:%M:%S")
          approved = @base.utc.strftime("%Y-%m-%d %H:%M:%S")
          sql("seed-#{label}", "INSERT INTO consumer_device_grants (user_id, client_name, device_code_digest, user_code_digest, expires_at, approved_at, scopes, created_at, updated_at) VALUES (#{person('pair_one').id}, 'Legacy #{label}', '${#{var}|digest}', 'unused-#{index}', '#{expires}', '#{approved}', #{value}, '#{approved}', '#{approved}')", at: at(index))
          token("legacy-poll-#{label}", var, at: at(20 + (index * 10)), save: { "access_token" => "tok-#{var}" })
        end
      end

      def cleanup_flow
        flow("cleanup")
        window = @base - 24 * 3600
        stamp = ->(time) { time.utc.strftime("%Y-%m-%d %H:%M:%S.%6N") }
        { "just-expired-more-than-a-day" => window - Rational(1, 1_000_000), "exactly-a-day" => window, "a-microsecond-newer" => window + Rational(1, 1_000_000), "future" => @base + 3600 }.each_with_index do |(label, expires), index|
          sql("seed-cleanup-#{label}", "INSERT INTO consumer_device_grants (client_name, device_code_digest, user_code_digest, expires_at, created_at, updated_at) VALUES ('Cleanup #{label}', 'cleanup-d-#{index}', 'cleanup-u-#{index}', '#{stamp.call(expires)}', '2026-11-01 00:00:00', '2026-11-01 00:00:00')")
        end
        device("device-triggers-cleanup", body: { "client_name" => "Cleaner" }, save: { "device_code" => "dev13", "user_code" => "user13" }, at: at(5))
        device("device-invalid-does-not-clean", body: {}, at: at(6))
      end

      def deleted_approver_flow
        flow("deleted-approver")
        device("device-deleted-approver", body: { "client_name" => "Doomed" }, save: { "device_code" => "dev14", "user_code" => "user14" })
        decide("decide-doomed", "pair_two", "${user14}", "allow", at: at(5))
        sql("approver-deleted-sql", "UPDATE users SET deleted_at = '2026-11-15 12:00:10' WHERE username = 'pair_two'", at: at(10))
        token("poll-deleted-approver", "dev14", at: at(30))
        token("poll-deleted-approver-again", "dev14", at: at(60))
        device("device-deleted-owner-upgrade", auth: bearer("tok:two-own"), body: { "client_name" => "Doomed", "scope" => BUNDLE }, at: at(70))
        revoke("revoke-deleted-owner-token", bearer("tok:two-own"), at: at(71))
      end

      def rate_limit_flow
        flow("rate-limit")
        @limits.enabled = true
        burst("device-burst", "#{PREFIX}/auth/device", body: { "client_name" => 5 }, count: 21)
        device("device-after-window", body: { "client_name" => "After Window" }, at: at(181), save: { "device_code" => "dev15", "user_code" => "user15" })
        burst("token-burst", "#{PREFIX}/auth/token", body: {}, count: 121, at: at(400))
        token("token-after-window", "dev15", at: at(461))
      end

      def write_pairing_outputs
        FileUtils.mkdir_p(File.join(@paths.out, "secrets"), mode: 0o700)
        File.write(File.join(@paths.out, "secrets", "secret_key_base"), ENV.fetch("SECRET_KEY_BASE"), perm: 0o600)
        File.write(File.join(@paths.out, "secrets", "pairing.json"), JSON.pretty_generate("tokens" => @raw, "passwords" => @people.transform_values { |entry| entry[:password] }, "handoff" => @handoff), perm: 0o600)
        document = { "format" => 1, "bundle_media_root" => @bundle_media, "extra_media_root" => @paths.media, "database" => "db/pre-scenario.sqlite3", "server_version" => Consumer::ServerInfo.server_version,
                     "schema_revision" => @manifest.dig("schema", "revision"), "origin" => @manifest.fetch("origin"), "users" => @people.transform_values { |entry| entry[:user].id },
                     "actors" => @people.keys, "final" => @final, "handoff" => { "database" => "db/handoff.sqlite3", "at" => iso(HANDOFF_AT) }, "steps" => @steps }
        File.write(File.join(@paths.out, "cases.json"), JSON.pretty_generate(document), perm: 0o600)
        Dir.glob("#{@paths.primary_db}*").each { |file| FileUtils.rm_f(file) }
        FileUtils.rm_rf(File.join(@paths.out, "scratch"))
      end
    end
  end
end
