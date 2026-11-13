# frozen_string_literal: true

require "test_helper"

class PinnedFileResponseBodyTest < ActiveSupport::TestCase
  setup do
    @file = Tempfile.new("pinned-response")
    @file.binmode
    @file.write("pinned bytes")
    @file.flush
  end

  teardown do
    @file.close unless @file.closed?
    @file.unlink
  end

  test "streams without exposing a pathname and closes after success" do
    body = PinnedFileResponseBody.new(@file)

    refute_respond_to body, :to_path
    assert_equal "pinned bytes", body.each.to_a.join
    assert @file.closed?
  end

  test "closes when the consumer raises" do
    body = PinnedFileResponseBody.new(@file)

    assert_raises(RuntimeError) do
      body.each { |_chunk| raise "client disconnected" }
    end

    assert @file.closed?
  end

  test "explicit close releases an unconsumed response descriptor" do
    body = PinnedFileResponseBody.new(@file)

    body.close
    body.close

    assert @file.closed?
  end

  test "streams only the requested slice and closes the pin" do
    body = PinnedFileResponseBody.new(@file, offset: 2, length: 4)
    assert_equal "nned", body.each.to_a.join
    assert @file.closed?
  end

  test "zero length is empty and closes the pin" do
    body = PinnedFileResponseBody.new(@file, offset: 2, length: 0)
    assert_empty body.each.to_a
    assert @file.closed?
  end
end
