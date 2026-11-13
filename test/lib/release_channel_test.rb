# frozen_string_literal: true

require "test_helper"

class ReleaseChannelTest < ActiveSupport::TestCase
  setup do
    @root = Dir.mktmpdir("release-channel")
    FileUtils.mkdir_p(File.join(@root, "config"))
  end

  teardown do
    FileUtils.remove_entry(@root)
  end

  test "this source tree is a 1.0 beta" do
    channel = Shelfarr::ReleaseChannel.load(Rails.root)

    assert_equal [ "beta", "1.0", "Shelfarr 1.0 Beta", "beta" ],
      [ channel.name, channel.series, channel.label, channel.image_channel_tag ]
    assert_same Shelfarr::ReleaseChannel.current, Shelfarr::ReleaseChannel.current
  end

  test "stable and beta builds of the same calendar number" do
    stable = write_channel("channel: stable\nseries: \"1.0\"\n")
    beta = write_channel("channel: beta\nseries: \"1.0\"\n")

    assert_equal [ "Shelfarr 1.0", "latest", "2026.11.16.1" ],
      [ stable.label, stable.image_channel_tag, stable.version_for("2026.11.16.1") ]
    assert_equal [ "Shelfarr 1.0 Beta", "beta", "2026.11.16.1-beta" ],
      [ beta.label, beta.image_channel_tag, beta.version_for("2026.11.16.1") ]
    assert_operator Gem::Version.new("2026.11.16.1-beta"), :<, Gem::Version.new("2026.11.16.1")
    assert_operator Gem::Version.new("2026.11.16.1-beta"), :>, Gem::Version.new("2026.11.09.1")
  end

  test "anything but a known channel and series is refused" do
    [
      "channel: nightly\nseries: \"1.0\"\n",
      "channel: Beta\nseries: \"1.0\"\n",
      "channel: \nseries: \"1.0\"\n",
      "channel: beta\nseries: 1.0\n",
      "channel: beta\nseries: \"one\"\n",
      "channel: beta\n",
      "channel: beta\nseries: \"1.0\"\nlatest: true\n",
      "- beta\n",
      "channel: [beta\n"
    ].each do |source|
      assert_raises(Shelfarr::ReleaseChannel::Invalid, source) { write_channel(source) }
    end
    File.delete(File.join(@root, Shelfarr::ReleaseChannel::SOURCE))
    assert_raises(Shelfarr::ReleaseChannel::Invalid) { Shelfarr::ReleaseChannel.load(@root) }
  end

  test "only calendar build numbers become published versions" do
    beta = Shelfarr::ReleaseChannel.new(name: "beta", series: "1.0")

    %w[0.1.0 2026.11.16 dev-a29a403 2026.11.16.1-rc].each do |version|
      assert_raises(Shelfarr::ReleaseChannel::Invalid, version) { beta.version_for(version) }
    end
    assert Shelfarr::ReleaseChannel.published_version?("2026.11.16.1")
    assert Shelfarr::ReleaseChannel.beta_version?("2026.11.16.1-beta")
    assert_not Shelfarr::ReleaseChannel.beta_version?("2026.11.16.1")
    assert_not Shelfarr::ReleaseChannel.published_version?("android-release-v2026.11.8.1")
  end

  private

  def write_channel(source)
    File.write(File.join(@root, Shelfarr::ReleaseChannel::SOURCE), source)
    Shelfarr::ReleaseChannel.load(@root)
  end
end
