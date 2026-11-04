# frozen_string_literal: true

module Rubocop
  module Cop
    module Shelfarr
      # Defined outside the RuboCop branch so eager load can execute it when the
      # gem is not required yet. RuboCop picks the same methods up via include.
      module ForceEncodingBehavior
        MSG = "Call `FilenameBytes.utf8`."
        RESTRICT_ON_SEND = %i[force_encoding].freeze

        def on_send(node)
          flag_force_encoding(node)
        end

        def on_csend(node)
          flag_force_encoding(node)
        end

        private

        def default_severity
          :warning
        end

        def flag_force_encoding(node)
          return if inside_filename_bytes?(node)

          add_offense(node, message: MSG)
        end

        def inside_filename_bytes?(node)
          node.each_ancestor(:class, :module).any? do |scope|
            scope_const_name(scope) == "FilenameBytes"
          end
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

      class ForceEncoding < base_class
        include ForceEncodingBehavior
      end
    end
  end
end
