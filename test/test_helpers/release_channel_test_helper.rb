# frozen_string_literal: true

module ReleaseChannelTestHelper
  extend ActiveSupport::Concern

  included do
    teardown do
      Shelfarr::ReleaseChannel.instance_variable_set(:@current, @original_release_channel) if defined?(@original_release_channel)
    end
  end

  def use_release_channel(name)
    @original_release_channel = Shelfarr::ReleaseChannel.current unless defined?(@original_release_channel)
    Shelfarr::ReleaseChannel.instance_variable_set(:@current, Shelfarr::ReleaseChannel.new(name: name, series: "1.0"))
  end
end
