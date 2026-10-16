# frozen_string_literal: true

class PublicationDecision
  DECISIONS = {
    hardlink_unsupported: [
      Errno::EXDEV,
      Errno::EPERM,
      Errno::EOPNOTSUPP,
      Errno::ENOTSUP,
      Errno::ENOSYS,
      Errno::EMLINK,
      Errno::EINVAL
    ].freeze,
    stale: [ Errno::ESTALE ].freeze,
    permission: [ Errno::EACCES ].freeze,
    missing: [ Errno::ENOENT ].freeze,
    bad_path: [ Errno::ELOOP, Errno::ENOTDIR ].freeze,
    already_present: [ Errno::EEXIST ].freeze,
    lock_busy: [ Errno::EWOULDBLOCK ].freeze
  }.freeze

  TABLE = DECISIONS.each_with_object({}) do |(decision, errnos), table|
    errnos.each { |errno| table[errno] = decision }
  end.freeze
  private_constant :DECISIONS, :TABLE

  def self.call(error)
    errno = error.is_a?(Class) ? error : error.class
    TABLE.fetch(errno, :refuse)
  end
end
