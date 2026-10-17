# frozen_string_literal: true

require "test_helper"
require "open3"

class UnkeyedFaradayMemoCopTest < ActiveSupport::TestCase
  test "a Faraday class instance variable without connection_settings_key is flagged" do
    report, status = lint(<<~SOURCE)
      class LintMemoClient
        class << self
          def connection
            @connection ||= Faraday.new(url: base_url) do |faraday|
              faraday.headers["X-Api-Key"] = api_key
            end
          end

          def self.other
            @other = Faraday::Connection.new
          end
        end

        def save
          @connection = Faraday.new
        end
      end
    SOURCE

    assert_equal 1, status.exitstatus, report.inspect
    offenses = offenses(report)
    assert_equal [ 4, 10 ], offenses.map { |offense| offense.dig("location", "start_line") }
    offenses.each do |offense|
      assert_equal "warning", offense.fetch("severity")
      assert_includes offense.fetch("message"), "connection_settings_key"
      assert_includes offense.fetch("message"), "settings the request sends"
    end
  end

  test "connection_settings_key keeps a Faraday memo" do
    report, status = lint(<<~SOURCE)
      class LintMemoClient
        class << self
          def connection
            @connection ||= Faraday.new(url: base_url)
          end

          private

          def connection_settings_key
            [ url, api_key ]
          end
        end
      end
    SOURCE

    assert status.success?, report.inspect
    assert_empty offenses(report)
  end

  test "a local built from Faraday is not a class instance variable assignment" do
    report, status = lint(<<~SOURCE)
      class LintMemoClient
        class << self
          def connection
            built = build_connection
            @connection = built
          end
        end
      end
    SOURCE

    assert status.success?, report.inspect
    assert_empty offenses(report)
  end

  private

  def lint(source)
    output, errors, status = Open3.capture3(
      Rails.root.join("bin/rubocop").to_s, "--only", "Shelfarr/UnkeyedFaradayMemo",
      "--force-exclusion", "--cache", "false", "--format", "json", "--fail-level", "warning",
      "--stdin", "app/services/indexer_clients/lint_memo.rb", stdin_data: source
    )
    assert_empty errors
    [ JSON.parse(output), status ]
  end

  def offenses(report)
    report.fetch("files").flat_map { |file| file.fetch("offenses") }
  end
end
