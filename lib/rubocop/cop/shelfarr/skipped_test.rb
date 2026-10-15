# frozen_string_literal: true

module Rubocop
  module Cop
    module Shelfarr
      if Object.const_defined?(:RuboCop, false) &&
          RuboCop.const_defined?(:Cop, false) &&
          RuboCop::Cop.const_defined?(:Base, false)
        class SkippedTest < ::RuboCop::Cop::Base
          MSG = "Minitest will not run `%<method>s`. Move it above `private`."
          FIXTURE = "test/lint/skipped_test_hidden_test.rb"

          class << self
            def prepare_test_runtime
              return if @prepared

              mutex.synchronize do
                return if @prepared

                require "minitest"
                require "pathname"
                install_autorun_guard
                ENV["RAILS_ENV"] = "test"
                test_dir = rails_root.join("test").to_s
                $LOAD_PATH.unshift(test_dir) unless $LOAD_PATH.include?(test_dir)
                require "test_helper"
                Minitest.seed ||= 0
                @prepared = true
              end
            end

            def rails_root
              @rails_root ||= Pathname.new(__dir__).join("../../../..").expand_path
            end

            def fixture_path
              @fixture_path ||= File.expand_path(FIXTURE, File.expand_path("../../../..", __dir__))
            end

            def fixture_explicitly_requested?
              expected = fixture_path
              ARGV.any? do |argument|
                next false if argument.start_with?("-")

                File.expand_path(argument) == expected
              rescue ArgumentError
                false
              end
            end

            def install_autorun_guard
              Minitest.define_singleton_method(:autorun) { nil }
            end

            def mutex
              @mutex ||= Mutex.new
            end
          end

          def on_new_investigation
            super
            path = processed_source.file_path
            return if path.nil? || !path.end_with?("_test.rb")
            return if fixture?(path) && !self.class.fixture_explicitly_requested?

            self.class.prepare_test_runtime
            require File.expand_path(path)
            flag_skipped_tests(File.expand_path(path))
          end

          def external_dependency_checksum
            self.class.fixture_explicitly_requested? ? "requested" : "omitted"
          end

          private

          def fixture?(path)
            File.expand_path(path) == self.class.fixture_path
          end

          def flag_skipped_tests(path)
            test_classes_in(path).each do |klass|
              skipped_methods(klass, path).each do |method_name, line|
                add_offense(
                  location_for(method_name, line),
                  message: format(MSG, method: method_name)
                )
              end
            end
          end

          def test_classes_in(path)
            ObjectSpace.each_object(Class).select do |klass|
              test_subclass?(klass) && own_test_methods(klass).any? { |name| method_defined_in?(klass, name, path) }
            end
          end

          def skipped_methods(klass, path)
            Minitest.seed ||= 0
            runnable = klass.runnable_methods
            own_test_methods(klass).filter_map do |method_name|
              next unless method_defined_in?(klass, method_name, path)
              next if runnable.include?(method_name)

              [ method_name, method_line(klass, method_name) ]
            end
          end

          def own_test_methods(klass)
            names = klass.instance_methods(false) + klass.private_instance_methods(false)
            names.map(&:to_s).uniq.select { |name| name.start_with?("test_") }
          end

          def method_defined_in?(klass, method_name, path)
            file, = method_source(klass, method_name)
            file && File.expand_path(file) == path
          end

          def method_line(klass, method_name)
            method_source(klass, method_name)&.last
          end

          def method_source(klass, method_name)
            klass.instance_method(method_name).source_location
          rescue NameError
            nil
          end

          def test_subclass?(klass)
            klass < Minitest::Test
          rescue TypeError
            false
          end

          def location_for(method_name, line)
            node = processed_source.ast&.each_node(:def)&.find do |def_node|
              def_node.method_name.to_s == method_name && def_node.loc.line == line
            end
            node ? node.loc.name : processed_source.buffer.line_range(line)
          end
        end
      else
        class SkippedTest
        end
      end
    end
  end
end
