# frozen_string_literal: true

require "test_helper"

class Kobo::DownloadRightsTest < ActiveSupport::TestCase
  URL = "https://storedownloads.kobo.com/download?signature=synthetic"

  def entry(format: "EPUB3", drm: "SignedNoDrm", url: URL, size: 1234)
    { "Format" => format, "DrmType" => drm, "Size" => size, "Url" => url }
  end

  test "only a full EPUB marked SignedNoDrm on Kobo's download host is DRM-free" do
    choice = Kobo::DownloadRights.classify([ entry(format: "KEPUB"), entry(format: "EPUB"), entry ])
    assert_equal [ "drm_free", "EPUB3", 1234, URL ], [ choice.rights, choice.format, choice.size, choice.url ]
    assert_equal "EPUB", Kobo::DownloadRights.classify([ entry(format: "EPUB", size: "99") ]).format
    assert_equal 99, Kobo::DownloadRights.classify([ entry(format: "EPUB", size: "99") ]).size
  end

  test "DRM, unverified labels, other formats and untrusted hosts are never DRM-free" do
    {
      [ entry(drm: "AdobeDrm"), entry(format: "KEPUB", drm: "KDRM") ] => "protected",
      [ entry(format: "EPUB3FL", drm: "KDRM") ] => "protected",
      [ entry(format: "KEPUB") ] => "unsupported",
      [ entry(drm: "None") ] => "unsupported",
      [ entry(drm: nil) ] => "unsupported",
      [ entry(format: "PDF", drm: "None") ] => "unsupported",
      [ entry(url: "http://storedownloads.kobo.com/download") ] => "unsupported",
      [ entry(url: "https://evil.example/download") ] => "unsupported",
      [ entry(url: "https://storedownloads.kobo.com.evil.example/download") ] => "unsupported",
      [ entry(url: "https://user:secret@storedownloads.kobo.com/download") ] => "unsupported",
      [ entry(url: "https://storedownloads.kobo.com:8443/download") ] => "unsupported",
      [ entry(url: "https://storedownloads.kobo.com/download#fragment") ] => "unsupported",
      [ entry(url: "https://storedownloads.kobo.com/a b") ] => "unsupported",
      [ entry(url: "https://storedownloads.kobo.com/%zz[") ] => "unsupported",
      [ entry(url: nil) ] => "unsupported",
      [] => "none_offered",
      nil => "none_offered",
      [ "not a hash" ] => "none_offered"
    }.each do |entries, rights|
      choice = Kobo::DownloadRights.classify(entries)
      assert_equal rights, choice.rights, entries.inspect
      assert_nil choice.url
    end
  end

  test "sizes outside the delivery limit are unknown rather than trusted" do
    [ 0, -1, "abc", KoboPublication::MAX_EPUB_BYTES + 1, nil ].each do |size|
      assert_nil Kobo::DownloadRights.classify([ entry(size: size) ]).size
    end
  end
end
