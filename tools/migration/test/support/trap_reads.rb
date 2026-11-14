# frozen_string_literal: true

require "pathname"

module TrapReads
  PROTECTED = [
    %r{/config/credentials}, %r{/config/master\.key}, %r{/config/[^/]*\.key\z}, %r{/storage/}, %r{\.sqlite3(-wal|-shm)?\z}, %r{\.encryption_keys}, %r{/\.env(?:\.[^/]*)?\z}
  ].freeze
  METHODS = %i[open read binread readlines foreach new].freeze

  module_function

  def record(path, log, allowed)
    text = path.respond_to?(:to_path) ? path.to_path : path
    return unless text.is_a?(String)

    expanded = File.expand_path(text)
    return if expanded.start_with?("#{allowed}/")
    return unless PROTECTED.any? { |pattern| pattern.match?(expanded) }

    File.write(log, "#{expanded}\n", mode: "a")
  end

  def install(log, allowed)
    hook = Module.new do
      METHODS.each do |name|
        define_method(name) do |path, *arguments, **options, &block|
          raise Errno::ENOENT if TrapReads.record(path, log, allowed)
          super(path, *arguments, **options, &block)
        end
      end
    end
    [ File.singleton_class, IO.singleton_class ].each { |target| target.prepend(hook) }
  end
end

TrapReads.install(ENV.fetch("TRAP_LOG"), ENV.fetch("TRAP_ALLOW")) if ENV["TRAP_LOG"]
