# frozen_string_literal: true

require "test_helper"

class PublicationDecisionTest < ActiveSupport::TestCase
  HISTORICAL_ROWS = [
    [ Errno::EXDEV, :hardlink_unsupported ],
    [ Errno::EPERM, :hardlink_unsupported ],
    [ Errno::EOPNOTSUPP, :hardlink_unsupported ],
    [ Errno::ENOTSUP, :hardlink_unsupported ],
    [ Errno::ENOSYS, :hardlink_unsupported ],
    [ Errno::EMLINK, :hardlink_unsupported ],
    [ Errno::EINVAL, :hardlink_unsupported ],
    [ Errno::ESTALE, :stale ],
    [ Errno::EACCES, :permission ],
    [ Errno::ENOENT, :missing ],
    [ Errno::ELOOP, :bad_path ],
    [ Errno::ENOTDIR, :bad_path ],
    [ Errno::EEXIST, :already_present ],
    [ Errno::EWOULDBLOCK, :lock_busy ]
  ].freeze

  test "decides the 14 historical errno rows" do
    HISTORICAL_ROWS.each do |errno, decision|
      assert_equal decision, PublicationDecision.call(errno.new), errno.name
    end
  end

  test "unlisted EIO refuses" do
    assert_equal :refuse, PublicationDecision.call(Errno::EIO.new)
  end

  test "CIFS linkat EINVAL stays hardlink_unsupported (#414)" do
    assert_equal :hardlink_unsupported, PublicationDecision.call(Errno::EINVAL.new)
  end

  test "NFS rename EINVAL stays hardlink_unsupported (#567)" do
    assert_equal :hardlink_unsupported, PublicationDecision.call(Errno::EINVAL.new)
  end

  test "CIFS post-processing ESTALE stays stale (#434)" do
    assert_equal :stale, PublicationDecision.call(Errno::ESTALE.new)
  end

  test "CIFS mtime ESTALE stays stale (#549)" do
    assert_equal :stale, PublicationDecision.call(Errno::ESTALE.new)
  end

  test "mkdirat EACCES stays permission (#469)" do
    assert_equal :permission, PublicationDecision.call(Errno::EACCES.new)
  end

  test "NFS flock EBADF stays refuse (#406)" do
    assert_equal :refuse, PublicationDecision.call(Errno::EBADF.new)
  end
end
