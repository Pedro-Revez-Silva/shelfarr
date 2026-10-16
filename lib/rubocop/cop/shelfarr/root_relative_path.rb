# frozen_string_literal: true

module Rubocop
  module Cop
    module Shelfarr
      if Object.const_defined?(:RuboCop, false) &&
          RuboCop.const_defined?(:Cop, false) &&
          RuboCop::Cop.const_defined?(:Base, false)
        class RootRelativePath < ::RuboCop::Cop::Base
          MSG = "Use the route helper or ApplicationHelper so `script_name` is kept."
          ROOT_RELATIVE = %r{\A/(?!/)}
          URL_KEYS = %i[href src action formaction url].freeze
          URL_ARGUMENTS = {
            link_to: 1, button_to: 1, link_to_if: 2, link_to_unless: 2,
            redirect_to: 0, redirect_back_or_to: 0, url_for: 0, form_tag: 0,
            image_tag: 0, javascript_include_tag: 0, stylesheet_link_tag: 0
          }.freeze
          # Tokenize comments and complete strings before applying URL patterns.
          # Only the start of a real string can be a URL, not an example inside it.
          SOURCE_TOKENS = %r{<!--.*?-->|<%\#.*?%>|//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`}m
          ERB_TAG = /<%(?!%)(?<indicator>\#|-?={1,2}|-)?(?<code>.*?)-?%>/m
          HTML_TAG = /<[A-Za-z](?:[^"'<>]|"[^"]*"|'[^']*')*>/m
          SCRIPT_TAG = /<script\b[^>]*>(?<code>.*?)<\/script\s*>/mi
          HTML_ATTRIBUTE = /
            \b(?:href|src|action|formaction)
            \s*=\s*
            ["'`]
            (?<path>\/(?!\/)[^"'`\s]*)
          /x
          RAW_PATTERNS = [
            /
              (?:href|src|action|formaction|url|path)
              \s*(?::|=>)
              \s*
              ["'`]
              (?<path>\/(?!\/)[^"'`\s]*)
            /x,
            HTML_ATTRIBUTE,
            /
              \b(?:fetch|(?:window\.)?location\.(?:assign|replace)|Turbo\.visit|Turbolinks\.visit)
              \s*\(\s*
              ["'`]
              (?<path>\/(?!\/)[^"'`\s]*)
            /x,
            /
              \blocation(?:\.href)?
              \s*=\s*
              ["'`]
              (?<path>\/(?!\/)[^"'`\s]*)
            /x,
            /
              \b(?:url|path|href|src|action|formaction)
              \s*=\s*
              ["'`]
              (?<path>\/(?!\/)[^"'`\s]*)
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
            while node.parent&.send_type? && node.parent.receiver == node && %i[+ freeze].include?(node.parent.method_name)
              node = node.parent
            end
            parent = node.parent
            return false unless parent
            return url_key?(parent.key) if parent.pair_type?
            return positional_argument?(parent, node) if parent.send_type? || parent.csend_type?

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
            position = URL_ARGUMENTS[parent.method_name]
            return false unless position

            if %i[link_to button_to].include?(parent.method_name) && parent.parent&.block_type?
              position = 0
            end

            parent.arguments[position] == node
          end

          def template_file?
            file_path.end_with?(".erb", ".js")
          end

          def file_path
            processed_source.file_path.to_s
          end

          def scan_raw_source
            source = original_source.raw_source
            erb_ranges = file_path.end_with?(".erb") ? scan_erb_ruby(source) : []
            html_ranges = source.to_enum(:scan, HTML_TAG).map { Regexp.last_match.begin(0)...Regexp.last_match.end(0) }
            script_ranges = source.to_enum(:scan, SCRIPT_TAG).map { Regexp.last_match.begin(:code)...Regexp.last_match.end(:code) }
            literal_starts = {}
            source.scan(SOURCE_TOKENS) do
              token = Regexp.last_match
              literal_starts[token.begin(0) + 1] = true if [ '"', "'", "`" ].include?(token[0][0])
            end
            erb_ranges.each do |range|
              literal_starts.delete_if { |position, _| range.cover?(position) }
            end
            seen = {}
            RAW_PATTERNS.each do |pattern|
              source.scan(pattern) do
                match = Regexp.last_match
                pos = match.begin(:path)
                next if seen[pos]
                next unless literal_starts[pos]
                if file_path.end_with?(".erb")
                  ranges = pattern.equal?(HTML_ATTRIBUTE) ? html_ranges : script_ranges
                  next unless ranges.any? { |range| range.cover?(pos) }
                end

                seen[pos] = true
                add_offense(path_range(match))
              end
            end
          end

          def scan_erb_ruby(source)
            source = source.gsub(/<!--.*?-->/m) { |comment| comment.gsub(/[^\n]/, " ") }
            # Keep character offsets while joining ERB Ruby sections into one program.
            # A newline at each closing tag separates adjacent expressions and comments.
            ruby = source.gsub(/[^\n]/, " ")
            ranges = []
            source.to_enum(:scan, ERB_TAG).each do
              match = Regexp.last_match
              ranges << (match.begin(0)...match.end(0))
              next if match[:indicator] == "#"

              ruby[match.begin(:code), match[:code].length] = match[:code]
              ruby[match.end(:code)] = "\n"
            end
            parsed = ::RuboCop::AST::ProcessedSource.new(
              ruby, processed_source.ruby_version, file_path, parser_engine: processed_source.parser_engine
            )
            parsed.ast&.each_node(:str, :dstr) do |node|
              next if node.str_type? && node.parent&.dstr_type?

              value = node.str_type? ? node.value : node.children.first
              value = value.value if value.respond_to?(:str_type?) && value.str_type?
              next unless root_relative?(value) && path_use?(node)

              location = node.loc.expression
              add_offense(Parser::Source::Range.new(original_source.buffer, location.begin_pos, location.end_pos))
            end
            ranges
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
