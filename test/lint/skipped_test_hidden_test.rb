# frozen_string_literal: true

require "test_helper"

class SkippedTestHiddenTest < ActiveSupport::TestCase
  private

  def test_hidden
    flunk "Minitest skips this method"
  end
end
