# frozen_string_literal: true

module Rubocop
  module Cop
    module Shelfarr
      if Object.const_defined?(:RuboCop, false) &&
          RuboCop.const_defined?(:Cop, false) &&
          RuboCop::Cop.const_defined?(:Base, false)
        class RescueToEmpty < ::RuboCop::Cop::Base
          MSG = "Return `RemoteResult::Failed` from this rescue. Do not use `[]`, `nil`, or `false`."

          def on_resbody(node)
            result = rescue_result(node)
            return unless empty_result?(result)

            add_offense(result || node, message: MSG)
          end

          private

          def rescue_result(node)
            body = node.body
            return if body.nil?

            body = body.children.last while body.begin_type? && body.children.any?
            body
          end

          def empty_result?(node)
            return true if node.nil?

            empty_literal?(node) || returned_empty?(node)
          end

          def returned_empty?(node)
            node.return_type? && (node.children.empty? || empty_literal?(node.children.first))
          end

          def empty_literal?(node)
            return false if node.nil?

            node.nil_type? || node.false_type? || (node.array_type? && node.children.empty?)
          end
        end
      else
        class RescueToEmpty
        end
      end
    end
  end
end
