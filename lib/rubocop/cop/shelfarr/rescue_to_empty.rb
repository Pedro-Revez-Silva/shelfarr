# frozen_string_literal: true

module Rubocop
  module Cop
    module Shelfarr
      # Defined outside the RuboCop branch so eager load can execute it when the
      # gem is not required yet. RuboCop picks the same methods up via include.
      module RescueToEmptyBehavior
        MSG = "Return `RemoteResult::Failed` from this rescue. Do not use `[]`, `nil`, or `false`, " \
              "including a modifier `return` and a rescue that returns `true`. " \
              "Match `RemoteResult::Failed` before `empty?` or string conversion."

        def on_resbody(node)
          body = node.body
          if body.nil?
            add_offense(node, message: MSG)
            return
          end

          each_return(body) do |statement|
            add_offense(statement, message: MSG) if empty_return?(statement)
          end

          result = final_expression(body)
          add_offense(result, message: MSG) if result && empty_value?(result) && !result.return_type?
        end

        def on_send(node)
          flag_conversion(node)
        end

        def on_csend(node)
          flag_conversion(node)
        end

        def on_dstr(node)
          node.each_child_node(:begin) do |wrapper|
            expression = wrapper.children.first
            next unless remote_flow?(expression)
            next if guarded?(expression)

            add_offense(wrapper, message: MSG)
          end
        end

        private

        def default_severity
          :warning
        end

        def flag_conversion(node)
          if node.method?(:empty?) || node.method?(:to_s) || node.method?(:to_str)
            receiver = node.receiver
            return unless receiver
            return unless unmatched_remote?(receiver, empty_check: node.method?(:empty?))

            add_offense(node, message: MSG)
          elsif node.method?(:+)
            flag_concatenation(node)
          end
        end

        def flag_concatenation(node)
          left = node.receiver
          right = node.first_argument
          if string_fragment?(left) && remote_flow?(right) && !guarded?(right)
            add_offense(node, message: MSG)
          elsif string_fragment?(right) && remote_flow?(left) && !guarded?(left)
            add_offense(node, message: MSG)
          end
        end

        def unmatched_remote?(receiver, empty_check:)
          return false if guarded?(receiver)
          return true if remote_flow?(receiver)
          return false unless empty_check

          lvar_name(receiver) == :result && !array_guarded?(receiver)
        end

        def remote_flow?(node)
          return false unless node
          return true if remote_constructor?(node)
          return false unless (name = lvar_name(node))

          scope = enclosing_scope(node)
          return false unless scope

          scope.each_descendant(:lvasgn).any? do |assignment|
            assignment.children.first == name && remote_constructor?(assignment.children[1])
          end
        end

        def remote_constructor?(node)
          return false unless node&.send_type? && node.method?(:new)

          const_path(node.receiver)&.start_with?("RemoteResult::")
        end

        def guarded?(node)
          name = lvar_name(node)
          return false unless name

          scope = enclosing_scope(node)
          return false unless scope

          scope.each_descendant(:send, :csend).any? { |send_node| failed_check?(send_node, name) } ||
            scope.each_descendant(:case).any? { |case_node| failed_case?(case_node, name) }
        end

        def array_guarded?(node)
          name = lvar_name(node)
          return false unless name

          scope = enclosing_scope(node)
          return false unless scope

          scope.each_descendant(:send, :csend).any? { |send_node| array_check?(send_node, name) }
        end

        def failed_check?(node, name)
          if node.method?(:failed?) && const_path(node.receiver) == "RemoteResult"
            argument = node.first_argument
            return lvar_name(argument) == name
          end

          return false unless node.method?(:is_a?) && lvar_name(node.receiver) == name

          const_path(node.first_argument) == "RemoteResult::Failed"
        end

        def array_check?(node, name)
          node.method?(:is_a?) && lvar_name(node.receiver) == name && const_path(node.first_argument) == "Array"
        end

        def failed_case?(node, name)
          condition = node.respond_to?(:condition) ? node.condition : node.children.first
          return false unless lvar_name(condition) == name

          branches = node.respond_to?(:when_branches) ? node.when_branches : node.each_child_node(:when).to_a
          branches.any? do |branch|
            conditions = branch.respond_to?(:conditions) ? branch.conditions : branch.children[0...-1]
            conditions.any? { |candidate| const_path(candidate) == "RemoteResult::Failed" }
          end
        end

        def enclosing_scope(node)
          node.each_ancestor(:def, :defs, :block).first || node.each_ancestor(:begin, :kwbegin).first
        end

        def lvar_name(node)
          return unless node&.lvar_type? || node&.lvasgn_type?

          node.children.first
        end

        def const_path(node)
          return unless node&.const_type?

          parts = []
          current = node
          while current&.const_type?
            parts.unshift(current.children[1].to_s)
            current = current.children[0]
          end
          parts.join("::")
        end

        def string_fragment?(node)
          node&.str_type? || node&.dstr_type?
        end

        def each_return(node)
          yield node if node.return_type?
          node.each_descendant(:return) { |statement| yield statement }
        end

        def empty_return?(node)
          value = node.children.first
          value.nil? || empty_value?(value)
        end

        def empty_value?(node)
          return false unless node

          node.nil_type? || node.false_type? || node.true_type? || empty_array?(node)
        end

        def empty_array?(node)
          node.array_type? && node.children.empty?
        end

        def final_expression(node)
          current = node
          while current && (current.type == :begin || current.type == :kwbegin)
            current = current.children.compact.last
          end
          current
        end
      end

      rubocop_loaded = Object.const_defined?(:RuboCop, false) &&
        RuboCop.const_defined?(:Cop, false) &&
        RuboCop::Cop.const_defined?(:Base, false)
      base_class = Object
      base_class = ::RuboCop::Cop::Base if rubocop_loaded

      class RescueToEmpty < base_class
        include RescueToEmptyBehavior
      end
    end
  end
end
