# frozen_string_literal: true

module Rubocop
  module Cop
    module Shelfarr
      # Defined outside the RuboCop branch so eager load can execute it when the
      # gem is not required yet. RuboCop picks the same methods up via include.
      module RestatedCommentBehavior
        MSG = "This comment restates the next line. Delete it. " \
              "Keep a comment that names a constraint the next line does not show."

        # Extra words from the eight restatements in the comment prototype.
        # A word stays off this list when one of the eight why comments needs it.
        NARRATION = %w[
          author
          case
          check
          collapse
          default
          full
          length
          limit
          name
          priority
          similarity
          simple
          status
          title
          trigram
          unchanged
          whitespace
        ].freeze

        STOPWORDS = %w[
          a an the to of for and or in on with from by as at be is are was were
          it its this that these those into also any them their than then not but
          if when so such via per out up we our you your do does did can may
          will just only over about between within without
        ].freeze

        def on_new_investigation
          super
          source_lines = processed_source.lines
          processed_source.comments.each do |comment|
            next unless comment.inline?

            code = annotated_code(comment, source_lines)
            next if code.nil?
            next unless restated?(comment.text, code)

            add_offense(comment.loc.expression, message: MSG)
          end
        end

        private

        def default_severity
          :warning
        end

        def annotated_code(comment, source_lines)
          line_number = comment.loc.line
          line = source_lines[line_number - 1]
          return unless line

          same_line = code_before_comment(line, comment)
          return same_line if same_line

          source_lines[line_number]
        end

        def code_before_comment(line, comment)
          range = comment.loc.expression
          line_start = processed_source.buffer.line_range(range.line).begin_pos
          prefix = line.byteslice(0, range.begin_pos - line_start)&.scrub
          return if prefix.nil? || !prefix.match?(/\S/)

          prefix
        end

        def restated?(comment_text, code_text)
          comment_words = words(comment_text)
          return false if comment_words.empty?

          code_words = words(code_text)
          extra = comment_words.reject { |word| code_words.include?(word) }
          extra.empty? || extra.all? { |word| NARRATION.include?(word) }
        end

        def words(text)
          expanded = text.to_s.scrub(" ")
          expanded = expanded.gsub(/([a-z\d])([A-Z])/, "\\1 \\2")
          expanded = expanded.gsub(/([A-Z]+)([A-Z][a-z])/, "\\1 \\2")
          expanded.downcase.scan(/[a-z0-9]+/).reject { |word| insignificant?(word) }
        end

        def insignificant?(word)
          word.length < 2 || STOPWORDS.include?(word)
        end
      end

      rubocop_loaded = Object.const_defined?(:RuboCop, false) &&
        RuboCop.const_defined?(:Cop, false) &&
        RuboCop::Cop.const_defined?(:Base, false)
      base_class = Object
      base_class = ::RuboCop::Cop::Base if rubocop_loaded

      class RestatedComment < base_class
        include RestatedCommentBehavior
      end
    end
  end
end
