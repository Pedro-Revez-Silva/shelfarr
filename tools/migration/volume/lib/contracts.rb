# frozen_string_literal: true

require_relative "comparison"

module Migration
  module Volume
    module Contracts
      QUEUE_GROWTH = %w[solid_queue_jobs solid_queue_ready_executions solid_queue_scheduled_executions solid_queue_claimed_executions solid_queue_failed_executions
                        solid_queue_blocked_executions solid_queue_pauses].freeze
      TOKEN_USE = { "api_tokens" => %w[last_used_at updated_at] }.freeze
      API_TOKENS_AFTER_UPGRADE = [
        'CREATE TABLE "api_tokens" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "created_at" datetime(6) NOT NULL, "expires_at" datetime(6), "last_used_at" datetime(6), ',
        '"name" varchar NOT NULL, "revoked_at" datetime(6), "scopes" text DEFAULT \'[]\' NOT NULL, "token_digest" varchar NOT NULL, "token_prefix" varchar NOT NULL, ',
        '"updated_at" datetime(6) NOT NULL, "user_id" integer, "issued_via" varchar, "replaces_api_token_id" integer, "connection_key" varchar, ',
        "CONSTRAINT \"fk_rails_f16b5e0447\"\nFOREIGN KEY (\"user_id\")\n  REFERENCES \"users\" (\"id\")\n)"
      ].join.freeze
      UPGRADE_ADDED_COLUMNS = { "api_tokens" => %w[issued_via replaces_api_token_id connection_key] }.freeze

      module_function

      def upgrade
        Allowances.new(mutable_columns: TOKEN_USE, new_row_tables: [ "schema_migrations" ] + QUEUE_GROWTH, new_tables: true, added_columns: UPGRADE_ADDED_COLUMNS,
                       new_tables_empty: false, volatile_files: [], definitions_after: { "api_tokens" => API_TOKENS_AFTER_UPGRADE })
      end

      def same_schema
        Allowances.new(mutable_columns: TOKEN_USE, new_row_tables: QUEUE_GROWTH, new_tables: false, added_columns: {}, new_tables_empty: false, volatile_files: [], definitions_after: {})
      end

      def retained_activity
        same_schema.merge(new_tables: false)
      end

      def strict
        Allowances.none
      end
    end
  end
end
