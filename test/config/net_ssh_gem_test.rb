# frozen_string_literal: true

require "test_helper"
require "net/ssh/proxy/jump"

class NetSshGemTest < ActiveSupport::TestCase
  test "activates net-ssh 7.3.8 or newer and refuses a later ProxyJump hop with shell metacharacters" do
    spec = Gem.loaded_specs.fetch("net-ssh")

    assert_operator spec.version, :>=, Gem::Version.new("7.3.8")

    injected = Net::SSH::Proxy::Jump.new("user@bastion.example,evil/x&$(cmd)")
    error = assert_raises(ArgumentError) { injected.build_proxy_command_equivalent }

    assert_match "jump host", error.message
    assert_nil injected.command_line_template

    safe = Net::SSH::Proxy::Jump.new("user@bastion.example,next.example")
    safe.build_proxy_command_equivalent

    assert_equal "ssh -l user -J next.example -W %h:%p bastion.example", safe.command_line_template
  end
end
