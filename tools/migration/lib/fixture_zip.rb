# frozen_string_literal: true

require "zlib"

module Migration
  module FixtureZip
    LOCAL = 0x04034b50
    CENTRAL = 0x02014b50
    EOCD = 0x06054b50
    UNIX_MADE_BY = 0x031e
    REGULAR = 0o100644 << 16
    DIRECTORY = (0o040755 << 16) | 0x10
    UTF8 = 0x0800
    DESCRIPTOR = 0x0008

    module_function

    def deflate(data)
      stream = Zlib::Deflate.new(Zlib::BEST_COMPRESSION, -Zlib::MAX_WBITS)
      stream.deflate(data, Zlib::FINISH).tap { stream.close }
    end

    def page(name, content = nil, **options)
      { name: name, data: content || "synthetic image #{name}".b * 3 }.merge(options)
    end

    def build(entries, eocd: {}, comment: "", before_eocd: "".b)
      body = "".b
      directory = "".b
      entries.each do |entry|
        data = entry.fetch(:data, "").b
        method = entry.fetch(:method, 8)
        stored = method == 8 ? deflate(data) : data
        name = entry.fetch(:name).b
        flags = entry.fetch(:flags) { name.bytes.all? { |byte| byte < 0x80 } ? 0 : UTF8 }
        fields = { crc: Zlib.crc32(data), compressed: stored.bytesize, size: data.bytesize, method: method, flags: flags, needed: 20, name: name }
        central = fields.merge(entry.fetch(:central, {}))
        descriptor = (flags & DESCRIPTOR).positive? || (central[:flags].to_i & DESCRIPTOR).positive?
        local = fields.merge(entry.fetch(:local, {}))
        local = local.merge(crc: 0, compressed: 0, size: 0) if descriptor && !entry[:local_sizes]
        offset = body.bytesize
        body << [ LOCAL, local[:needed], local[:flags], local[:method], 0, 0x21, local[:crc], local[:compressed], local[:size], local[:name].bytesize, entry.fetch(:local_extra, "").bytesize ].pack("VvvvvvVVVvv")
        body << local[:name] << entry.fetch(:local_extra, "").b << stored
        body << [ fields[:crc], fields[:compressed], fields[:size] ].pack("VVV") if descriptor && !entry[:no_descriptor]
        extra = entry.fetch(:central_extra, "").b
        directory << [ CENTRAL, entry.fetch(:made_by, UNIX_MADE_BY), central[:needed], central[:flags], central[:method], 0, 0x21, central[:crc], central[:compressed], central[:size],
                       central[:name].bytesize, extra.bytesize, entry.fetch(:file_comment, "").bytesize, entry.fetch(:disk, 0), 0, entry.fetch(:external, REGULAR), entry.fetch(:offset, offset) ].pack("VvvvvvvVVVvvvvvVV")
        directory << central[:name] << extra << entry.fetch(:file_comment, "").b
      end
      record = { disk: 0, directory_disk: 0, disk_entries: entries.size, entries: entries.size, directory_size: directory.bytesize, directory_offset: body.bytesize }.merge(eocd)
      body + directory + before_eocd.b + [ EOCD, record[:disk], record[:directory_disk], record[:disk_entries], record[:entries], record[:directory_size], record[:directory_offset], comment.bytesize ].pack("VvvvvVVv") + comment.b
    end

    def zip64_locator
      [ 0x07064b50, 0, 0, 1 ].pack("VVQ<V")
    end

    def extra(identifier, payload = "")
      [ identifier, payload.bytesize ].pack("vv") + payload.b
    end
  end
end
