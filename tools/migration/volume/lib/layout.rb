# frozen_string_literal: true

module Migration
  module Volume
    module Layout
      PRIMARY = "production.sqlite3"
      QUEUE = "production_queue.sqlite3"
      CABLE = "production_cable.sqlite3"
      CACHE = "production_cache.sqlite3"
      DATABASES = [ PRIMARY, QUEUE, CABLE, CACHE ].freeze
      SIDECAR_SUFFIXES = %w[-wal -shm -journal].freeze
      SECRET_KEY_BASE = ".secret_key_base"
      ENCRYPTION_KEYS = ".encryption_keys"
      KEY_FILES = [ SECRET_KEY_BASE, ENCRYPTION_KEYS ].freeze
      MEDIA_ROOTS = { "/audiobooks" => "audiobooks", "/ebooks" => "ebooks" }.freeze

      Semantics = Data.define(:file, :role, :persistence, :on_upgrade)

      SEMANTICS = [
        Semantics.new(PRIMARY, "primary", "system of record", "every released row and column preserved; new tables empty until used"),
        Semantics.new(QUEUE, "queue", "durable Ruby background work", "jobs and executions preserved row for row; never purged or drained; unknown classes retained and reported blocked"),
        Semantics.new(CABLE, "cable", "one day broadcast buffer", "must open; contents disposable"),
        Semantics.new(CACHE, "cache", "disposable cache", "must open; contents disposable")
      ].freeze

      RUNTIME_QUEUE_TABLES = %w[solid_queue_processes solid_queue_semaphores solid_queue_recurring_tasks solid_queue_recurring_executions].freeze

      module_function

      def database?(name) = DATABASES.include?(name)

      def sidecar?(name) = DATABASES.any? { |database| SIDECAR_SUFFIXES.any? { |suffix| name == "#{database}#{suffix}" } }
    end
  end
end
