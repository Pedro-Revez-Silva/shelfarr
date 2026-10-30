# frozen_string_literal: true

class FilenameBytes
  # Directory listings and syscall buffers have no encoding argument.
  # Retag the bytes as UTF-8. Transcoding would reject non-ASCII bytes
  # that are already UTF-8.
  def self.utf8(value)
    name = value.to_s.dup
    name.force_encoding(Encoding::UTF_8)
    raise EncodingError, "filename bytes are not valid UTF-8" unless name.valid_encoding?

    name
  end
end
