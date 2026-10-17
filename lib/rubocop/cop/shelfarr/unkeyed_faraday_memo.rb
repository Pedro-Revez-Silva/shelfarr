# frozen_string_literal: true

module Rubocop
  module Cop
    module Shelfarr
      if Object.const_defined?(:RuboCop, false) &&
          RuboCop.const_defined?(:Cop, false) &&
          RuboCop::Cop.const_defined?(:Base, false)
        class UnkeyedFaradayMemo < ::RuboCop::Cop::Base
          MSG = "Key the memo on the settings the request sends with `connection_settings_key`."

          def on_ivasgn(node)
            value = node.children[1]
            return if value.nil?

            investigate(node, value)
          end

          def on_or_asgn(node)
            investigate_operator_assignment(node)
          end

          def on_and_asgn(node)
            investigate_operator_assignment(node)
          end

          def on_op_asgn(node)
            investigate_operator_assignment(node)
          end

          private

          def investigate_operator_assignment(node)
            lhs = node.children.first
            return unless lhs&.ivasgn_type?

            investigate(node, node.children.last)
          end

          def investigate(assignment, value)
            return unless class_instance_variable?(assignment)
            return unless faraday_source?(value)
            return if defines_connection_settings_key?(assignment)

            add_offense(assignment)
          end

          def class_instance_variable?(node)
            scope = node.each_ancestor(:def, :defs, :sclass, :class, :module).first
            return false unless scope
            return true if scope.defs_type? || scope.sclass_type? || scope.class_type? || scope.module_type?
            return false unless scope.def_type?

            scope.each_ancestor(:sclass).any?
          end

          def faraday_source?(node)
            return false if node.nil?
            return faraday_source?(node.children.compact.last) if node.begin_type? || node.kwbegin_type?
            return faraday_source?(node.send_node) if node.block_type? || node.numblock_type?
            return false unless node.send_type? || node.csend_type?

            faraday_const?(node.receiver)
          end

          def faraday_const?(node)
            return false unless node&.const_type?

            name = node.const_name
            name == "Faraday" || name.to_s.start_with?("Faraday::")
          end

          def defines_connection_settings_key?(node)
            class_node = node.each_ancestor(:class).first
            return false unless class_node

            key_method?(class_node.body)
          end

          def key_method?(node)
            return false if node.nil?
            return node.method_name == :connection_settings_key if node.def_type? || node.defs_type?
            return false unless node.begin_type? || node.kwbegin_type? || node.sclass_type?

            node.children.any? { |child| key_method?(child) }
          end
        end
      else
        class UnkeyedFaradayMemo
        end
      end
    end
  end
end
