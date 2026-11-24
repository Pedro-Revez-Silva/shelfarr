# frozen_string_literal: true

require "test_helper"
require "open3"
require "rubocop"
require Rails.root.join("lib/rubocop/cop/shelfarr/restated_comment")

class RestatedCommentCopTest < ActiveSupport::TestCase
  FIXTURE = <<~RUBY
    # Pin minitest to a compatible version with Rails 8.1
    gem "minitest", "~> 5.25"

    # Cancel/fail request permanently. Also cancels any active downloads and removes them from download clients
    def cancel!(allow_direct_recovery: false)
    end

    def validate_external_attributes!(filesystem, attributes)
      return unless filesystem == 3 # Unix
    end

    def parse_mp4_meta_atom(file)
      file.seek(4, IO::SEEK_CUR) # version and flags
    end

    weights = {
      health: 5       # Seeders/availability (for torrents)
    }

    begin
      link
    # Include EINVAL: some network filesystems (notably CIFS) report
    # "hardlink unsupported" that way instead of EXDEV/EOPNOTSUPP.
    rescue Errno::EXDEV, Errno::EPERM, Errno::EOPNOTSUPP, Errno::ENOTSUP,
        Errno::ENOSYS, Errno::EMLINK, Errno::EINVAL, Fiddle::DLError, NotImplementedError
    end

    # Remove quotes first: transliteration replaces curly apostrophes with "?".
    normalized = ActiveSupport::Inflector.transliterate(text.to_s.delete(MATCHING_QUOTE_CHARACTERS))

    # Minimum title-only similarity required before author similarity can contribute to score
    # This prevents false positives when books share author + series text but have different core titles
    # Example: "Harry Potter und die Kammer des Schreckens" vs "Harry Potter und der Gefangene von Askaban"
    # should not match despite sharing author and series metadata
    MIN_TITLE_SIMILARITY = FUZZY_THRESHOLD

    def tidy(value)
      value
        .gsub(/\\s+/, " ") # Collapse whitespace
        .truncate(100, omission: "") # Limit length
        .split.map(&:capitalize) # Title case
    end

    def string_similarity(str1, str2)
      # Simple trigram similarity
      trigrams1 = to_trigrams(str1)
    end

    def unchanged(result)
      assert result.pending? # Status unchanged
    end

    def append
      rpc([
        0, # Priority
      ])
    end

    def calculate_author_score(title)
      # Check for full author name
      return 100 if matching_text_variants(title).any?
    end

    def infer_extension
      # Default to epub
      "epub"
    end

    def label(book)
      # book title
      book.title
    end

    def same_line(book)
      book.title # book title
    end

    def marked
      "ü book" # book title
    end

    # ---
    keep = 1

    # NFS lock is not a row lock
  RUBY

  RESTATEMENTS = [
    "Collapse whitespace",
    "Limit length",
    "Title case",
    "Simple trigram similarity",
    "Status unchanged",
    "Priority",
    "Check for full author name",
    "Default to epub",
    "book title",
    "book title",
    "book title"
  ].freeze

  test "flags the eight restatements and keeps the eight why comments" do
    offenses = investigate(FIXTURE)
    assert_equal RESTATEMENTS, comment_bodies(FIXTURE, offenses.map { |offense| offense.line })
    offenses.each do |offense|
      assert_equal :warning, offense.severity.name
      assert_includes offense.message, "restates the next line"
      assert_includes offense.message, "Delete it"
      assert_includes offense.message, "constraint the next line does not show"
    end
    assert_equal :warning, Rubocop::Cop::Shelfarr::RestatedComment.new.send(:default_severity)

    report, status = lint(FIXTURE)
    assert_equal 1, status.exitstatus, report.inspect
    cli_offenses = offenses_from(report)
    assert_equal RESTATEMENTS, comment_bodies(FIXTURE, cli_offenses.map { |offense| offense.dig("location", "start_line") })
    cli_offenses.each do |offense|
      assert_equal "warning", offense.fetch("severity")
      assert_equal "Shelfarr/RestatedComment", offense.fetch("cop_name")
      assert_includes offense.fetch("message"), "restates the next line"
      assert_includes offense.fetch("message"), "Delete it"
      assert_includes offense.fetch("message"), "constraint the next line does not show"
    end
  end

  private

  def investigate(source)
    config = RuboCop::ConfigLoader.load_file(Rails.root.join(".rubocop.yml").to_s)
    processed = RuboCop::ProcessedSource.new(source, 3.3, Rails.root.join("app/services/restated_comment_lint.rb").to_s)
    team = RuboCop::Cop::Team.mobilize([ Rubocop::Cop::Shelfarr::RestatedComment ], config)
    report = team.investigate(processed)
    assert_empty report.errors, report.errors.inspect
    report.offenses
  end

  def lint(source)
    output, errors, status = Open3.capture3(
      Rails.root.join("bin/rubocop").to_s, "--only", "Shelfarr/RestatedComment",
      "--force-exclusion", "--cache", "false", "--format", "json", "--fail-level", "warning",
      "--stdin", "app/services/restated_comment_lint.rb", stdin_data: source
    )
    assert_empty errors
    [ JSON.parse(output), status ]
  end

  def offenses_from(report)
    report.fetch("files").flat_map { |file| file.fetch("offenses") }
  end

  def comment_bodies(source, lines)
    source_lines = source.lines
    lines.map { |line| source_lines[line - 1][/#\s*(.*)/, 1] }
  end
end
