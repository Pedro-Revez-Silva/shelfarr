# frozen_string_literal: true

module Rubocop
  module Cop
    module Shelfarr
      if Object.const_defined?(:RuboCop, false) &&
          RuboCop.const_defined?(:Cop, false) &&
          RuboCop::Cop.const_defined?(:Base, false)
        class ShortConcurrencyLease < ::RuboCop::Cop::Base
          MSG = "A 10 minute `limits_concurrency` duration is not a lock. Hold the lease until `perform` returns."
          RESTRICT_ON_SEND = %i[limits_concurrency].freeze

          def on_send(node)
            duration = duration_argument(node)
            return unless duration && ten_minutes?(duration)
            return if holds_lease_until_perform?(node)

            add_offense(duration)
          end

          private

          def default_severity
            :warning
          end

          def duration_argument(node)
            node.arguments.each do |argument|
              next unless argument.hash_type? || argument.respond_to?(:pairs)

              pair = argument.pairs.find { |candidate| duration_key?(candidate) }
              return pair.value if pair
            end
            nil
          end

          def duration_key?(pair)
            key = pair.key
            if key.sym_type?
              key.value == :duration
            elsif key.str_type?
              key.value.to_sym == :duration
            else
              false
            end
          end

          def ten_minutes?(node)
            node.send_type? && node.method?(:minutes) && node.receiver&.int_type? && node.receiver.value == 10
          end

          def holds_lease_until_perform?(node)
            node.each_ancestor(:class, :module).any? do |scope|
              scope.each_descendant(:send).any? { |send_node| lease_install?(send_node) }
            end
          end

          def lease_install?(send_node)
            return false unless send_node.method?(:install!)

            receiver = send_node.receiver
            receiver&.source&.match?(/\A(?:[A-Z]\w*::)*ConcurrencyLease\z/)
          end
        end
      else
        class ShortConcurrencyLease
        end
      end
    end
  end
end
