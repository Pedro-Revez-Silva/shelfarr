# frozen_string_literal: true

module Rubocop
  module Cop
    module Shelfarr
      # Defined outside the RuboCop branch so eager load can execute it when the
      # gem is not required yet. RuboCop picks the same methods up via include.
      module SelfEnqueueBehavior
        MSG = "Use `config/recurring.yml` for a clock, or `SingleChain.enqueue` for one continuation."
        RESTRICT_ON_SEND = %i[perform_later].freeze

        def on_send(node)
          return if inside_single_chain_enqueue?(node)
          return unless same_class_target?(node)

          add_offense(node, message: MSG)
        end

        private

        def default_severity
          :warning
        end

        def inside_single_chain_enqueue?(node)
          node.each_ancestor(:def, :defs).any? do |method_node|
            next false unless method_node.method_name == :enqueue

            method_node.each_ancestor(:class, :module).any? do |scope|
              scope_const_name(scope) == "SingleChain"
            end
          end
        end

        def same_class_target?(node)
          class_name = enclosing_class_name(node)
          return false unless class_name

          receiver_names_class?(node.receiver, node, class_name)
        end

        def receiver_names_class?(receiver, node, class_name)
          return singleton_context?(node) if receiver.nil?
          return singleton_context?(node) if receiver.self_type?
          return true if self_class?(receiver)
          return receiver.children.last.to_s == class_name if receiver.const_type?
          return receiver_names_class?(receiver.receiver, node, class_name) if set_call?(receiver)

          false
        end

        def self_class?(receiver)
          receiver.send_type? && receiver.method?(:class) && receiver.receiver&.self_type?
        end

        def set_call?(receiver)
          receiver.send_type? && receiver.method?(:set)
        end

        def singleton_context?(node)
          return true if node.each_ancestor(:sclass).any?

          node.each_ancestor(:defs).any? { |defs_node| defs_node.children[0]&.self_type? }
        end

        def enclosing_class_name(node)
          class_node = node.each_ancestor(:class).first
          return unless class_node

          scope_const_name(class_node)
        end

        def scope_const_name(scope)
          identifier = scope.children[0]
          return unless identifier.respond_to?(:const_type?) && identifier.const_type?

          identifier.children.last.to_s
        end
      end

      rubocop_loaded = Object.const_defined?(:RuboCop, false) &&
        RuboCop.const_defined?(:Cop, false) &&
        RuboCop::Cop.const_defined?(:Base, false)
      base_class = Object
      base_class = ::RuboCop::Cop::Base if rubocop_loaded

      class SelfEnqueue < base_class
        include SelfEnqueueBehavior
      end
    end
  end
end
