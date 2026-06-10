# frozen_string_literal: true

require "test_helper"

class OutboundUrlGuardTest < ActiveSupport::TestCase
  test "allows public addresses" do
    uri = OutboundUrlGuard.validate!("https://example.test/file.epub")

    assert_equal "example.test", uri.host
    assert_equal "203.0.113.10", uri.ipaddr
    assert uri.use_ssl?
  end

  test "rejects non-http schemes and missing hosts" do
    assert_raises(OutboundUrlGuard::BlockedUrlError) { OutboundUrlGuard.validate!("file:///etc/passwd") }
    assert_raises(OutboundUrlGuard::BlockedUrlError) { OutboundUrlGuard.validate!("ftp://example.test/file") }
    assert_raises(OutboundUrlGuard::BlockedUrlError) { OutboundUrlGuard.validate!("not a url") }
    assert_raises(OutboundUrlGuard::BlockedUrlError) { OutboundUrlGuard.validate!(nil) }
  end

  test "rejects private addresses by default" do
    %w[
      http://127.0.0.1/file
      http://localhost/file
      http://10.0.0.5/file
      http://172.16.10.10/file
      http://192.168.1.80:4567/file
      http://[::1]/file
    ].each do |url|
      assert_raises(OutboundUrlGuard::BlockedUrlError, "expected #{url} to be blocked") do
        OutboundUrlGuard.validate!(url)
      end
    end
  end

  test "allows private addresses when allow_private is set" do
    uri = OutboundUrlGuard.validate!("http://192.168.1.80:4567/search", allow_private: true)

    assert_equal "192.168.1.80", uri.host
    assert_equal "192.168.1.80", uri.ipaddr
  end

  test "always rejects link-local and metadata addresses" do
    %w[
      http://169.254.169.254/latest/meta-data
      http://0.0.0.0/file
      http://[fe80::1]/file
      http://[64:ff9b::a9fe:a9fe]/file
    ].each do |url|
      assert_raises(OutboundUrlGuard::BlockedUrlError, "expected #{url} to be blocked") do
        OutboundUrlGuard.validate!(url, allow_private: true)
      end
    end
  end

  test "rejects IPv4-mapped IPv6 forms of blocked and private addresses" do
    assert_raises(OutboundUrlGuard::BlockedUrlError) do
      OutboundUrlGuard.validate!("http://[::ffff:169.254.169.254]/latest/meta-data", allow_private: true)
    end

    %w[
      http://[::ffff:127.0.0.1]/file
      http://[::ffff:10.0.0.5]/file
      http://[::ffff:192.168.1.80]/file
    ].each do |url|
      assert_raises(OutboundUrlGuard::BlockedUrlError, "expected #{url} to be blocked") do
        OutboundUrlGuard.validate!(url)
      end
    end
  end

  test "rejects hostnames that resolve to private addresses" do
    with_resolver(->(host) { [ "10.0.0.5" ] }) do
      assert_raises(OutboundUrlGuard::BlockedUrlError) do
        OutboundUrlGuard.validate!("https://internal.test/file.epub")
      end
    end
  end

  test "rejects hostnames when any resolved address is blocked" do
    with_resolver(->(host) { [ "203.0.113.10", "169.254.169.254" ] }) do
      assert_raises(OutboundUrlGuard::BlockedUrlError) do
        OutboundUrlGuard.validate!("https://rebinding.test/file.epub", allow_private: true)
      end
    end
  end

  test "rejects unresolvable hostnames" do
    with_resolver(->(host) { [] }) do
      assert_raises(OutboundUrlGuard::BlockedUrlError) do
        OutboundUrlGuard.validate!("https://unknown.test/file.epub")
      end
    end
  end

  test "pins the first validated resolved address" do
    with_resolver(->(host) { [ "203.0.113.10", "203.0.113.11" ] }) do
      uri = OutboundUrlGuard.validate!("https://downloads.test/file.epub")

      assert_equal "downloads.test", uri.host
      assert_equal "203.0.113.10", uri.ipaddr
    end
  end

  test "obviously_private_host? detects localhost and private literals" do
    assert OutboundUrlGuard.obviously_private_host?("localhost")
    assert OutboundUrlGuard.obviously_private_host?("127.0.0.1")
    assert OutboundUrlGuard.obviously_private_host?("192.168.1.80")
    assert OutboundUrlGuard.obviously_private_host?("169.254.169.254")
    assert_not OutboundUrlGuard.obviously_private_host?("example.test")
    assert_not OutboundUrlGuard.obviously_private_host?("8.8.8.8")
  end

  private

  def with_resolver(resolver)
    previous = OutboundUrlGuard.resolver
    OutboundUrlGuard.resolver = resolver
    yield
  ensure
    OutboundUrlGuard.resolver = previous
  end
end
