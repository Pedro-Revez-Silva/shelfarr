# frozen_string_literal: true

module Rubocop
  module Cop
    module Shelfarr
      if Object.const_defined?(:RuboCop, false) &&
          RuboCop.const_defined?(:Cop, false) &&
          RuboCop::Cop.const_defined?(:Base, false)
        class RootRelativePath < ::RuboCop::Cop::Base
          MSG = "Use the route helper or ApplicationHelper so `script_name` is kept."
          ROOT_RELATIVE = %r{\A/(?!/)[A-Za-z0-9_]}
          URL_KEYS = %i[href src action formaction url path].freeze
          NON_PATH_METHODS = %i[
            start_with? end_with? delete_prefix delete_suffix
            chomp chomp! include? exclude? match match?
            gsub sub gsub! sub! split index rindex
            delete delete!
          ].freeze
          ASSIGNMENT_TYPES = %i[lvasgn ivasgn cvasgn gvasgn casgn or_asgn and_asgn op_asgn].freeze
          RAW_PATTERNS = [
            /
              (?:href|src|action|formaction|url|path)
              \s*(?::|=>)
              \s*
              ["'`]
              (?<path>\/(?!\/)[A-Za-z0-9_][^"'`\s]*)
            /x,
            /
              \b(?:href|src|action|formaction)
              \s*=\s*
              ["'`]
              (?<path>\/(?!\/)[A-Za-z0-9_][^"'`\s]*)
            /x,
            /
              \b(?:button_to|link_to|link_to_if|link_to_unless|redirect_to|redirect_back_or_to|url_for|form_tag)
              \s*\(?\s*
              (?:["'][^"'\n]*["']\s*,\s*)?
              ["'`]
              (?<path>\/(?!\/)[A-Za-z0-9_][^"'`\s]*)
            /x,
            /
              \b(?:fetch|assign|replace|visit)
              \s*\(\s*
              ["'`]
              (?<path>\/(?!\/)[A-Za-z0-9_][^"'`\s]*)
            /x,
            /
              \blocation(?:\.href)?
              \s*=\s*
              ["'`]
              (?<path>\/(?!\/)[A-Za-z0-9_][^"'`\s]*)
            /x,
            /
              (?:const|let|var|@?[A-Za-z_][A-Za-z0-9_]*)
              \s*=\s*
              ["'`]
              (?<path>\/(?!\/)[A-Za-z0-9_][^"'`\s]*)
            /x
          ].freeze

          def on_new_investigation
            super
            return unless template_file?

            scan_raw_source
          end

          def on_str(node)
            return if template_file?
            return if node.parent&.dstr_type?

            flag_node(node, node.value)
          end

          def on_dstr(node)
            return if template_file?

            first = node.children.first
            return unless first&.str_type?

            flag_node(node, first.value)
          end

          def on_other_file
            super
            scan_raw_source
          end

          private

          def flag_node(node, value)
            return unless root_relative?(value)
            return unless path_use?(node)

            add_offense(node)
          end

          def root_relative?(value)
            value.is_a?(String) && value.match?(ROOT_RELATIVE)
          end

          def path_use?(node)
            parent = node.parent
            return false unless parent
            return url_key?(parent.key) if parent.pair_type?
            return positional_argument?(parent, node) if parent.send_type? || parent.csend_type?
            return true if parent.type?(*ASSIGNMENT_TYPES)
            return true if parent.array_type? || parent.return_type?
            return true if parent.type?(:def, :defs, :block, :begin, :kwbegin)

            false
          end

          def url_key?(key)
            name = if key.sym_type?
              key.value
            elsif key.str_type?
              key.value.to_sym
            end
            URL_KEYS.include?(name)
          end

          def positional_argument?(parent, node)
            return false if NON_PATH_METHODS.include?(parent.method_name)

            parent.arguments.include?(node)
          end

          def template_file?
            file_path.end_with?(".erb", ".js")
          end

          def file_path
            processed_source.file_path.to_s
          end

          def scan_raw_source
            source = original_source.raw_source
            seen = {}
            RAW_PATTERNS.each do |pattern|
              source.scan(pattern) do
                match = Regexp.last_match
                pos = match.begin(:path)
                next if seen[pos]

                seen[pos] = true
                add_offense(path_range(match))
              end
            end
          end

          def original_source
            @current_original || processed_source
          end

          def path_range(match)
            Parser::Source::Range.new(original_source.buffer, match.begin(:path), match.end(:path))
          end
        end

        RuboCop::Runner.ruby_extractors.unshift(
          lambda { |processed_source|
            path = processed_source.path.to_s
            return nil unless path.end_with?(".erb", ".js")

            dummy = RuboCop::AST::ProcessedSource.new(
              "nil\n",
              processed_source.ruby_version,
              processed_source.path,
              parser_engine: processed_source.parser_engine
            )
            [ { offset: 0, processed_source: dummy } ]
          }
        )
      else
        class RootRelativePath
        end
      end
    end
  end
end
