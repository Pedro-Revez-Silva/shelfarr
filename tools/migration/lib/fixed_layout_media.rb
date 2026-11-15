# frozen_string_literal: true

require "fileutils"
require_relative "fixture_zip"

module Migration
  module FixedLayoutMedia
    Z = FixtureZip
    NATURAL_PAGES = [
      "Page 2.png", "page 10.PNG", "Page 1.jpg", "page 001.png", "Page 01.webp", "page 1.JPEG", "Éclair 2.png", "éclair 10.png", "Σ1.png", "ΑΣ.png", "Αςb.png", "İ2.png", "i̇2.png",
      "p99999999999999999999.png", "p100000000000000000000.png", "ch1/a.png", "ch10/a.png", "CH2/a.png", "Ch2/b.png", "chapter 1/Z.jpg", "chapter 1/a.jpg", "日本語/二.png", "日本語/十.png",
      "a b+c%d é;#?.png", "cover.JPEG", "no_extension", "a.png.txt", "x.gif", "x.bmp", "ǅ3.png", "ǆ3.png", "ｆｕｌｌ１.png", "z".encode("UTF-8") + "̈.png", "ß.png", "ẞ.png", "\u{A7CC}1.png", "\u{A7CD}1.png", "\u{10D50}2.png", "\u{10D70}2.png", "\u{1C89}3.png", "\u{1C8A}3.png"
    ].freeze
    HIDDEN_PAGES = [ ".hidden.png", "dir/.hidden.png", "__MACOSX/page.png", "dir/__MACOSX/page.png", "._page 1.png", ".dir/page.png" ].freeze

    module_function

    def natural_pages
      entries = NATURAL_PAGES.each_with_index.map { |name, index| Z.page(name, "page #{index} #{name}".b * (1 + index), method: index.even? ? 8 : 0) }
      entries += HIDDEN_PAGES.map { |name| Z.page(name) }
      entries << { name: "folder/", data: "", method: 0, external: Z::DIRECTORY }
      entries << Z.page("described.png", flags: Z::DESCRIPTOR)
      Z.build(entries)
    end

    def simple_pages(count = 3, method: 8)
      Z.build(Array.new(count) { |index| Z.page(format("p%02d.png", index + 1), "image #{index}".b * 40, method: method) })
    end

    def many_pages(count)
      Z.build(Array.new(count) { |index| Z.page(format("%05d.png", index), "x", method: 0) })
    end

    def deflated_lie(size)
      Z.build([ Z.page("big.png", "x", central: { size: size }, local: { size: size }) ])
    end

    def total_over_limit
      Z.build(Array.new(65) { |index| Z.page(format("%02d.png", index), "x", central: { size: 32 * 1024 * 1024 }, local: { size: 32 * 1024 * 1024 }) })
    end

    def overlapping_entries
      inner = Z.page("b.png", "inner image", method: 0)
      embedded = Z.build([ inner ])[0, 30 + "b.png".bytesize + "inner image".bytesize]
      outer = Z.page("a.png", "12345".b + embedded, method: 0)
      Z.build([ outer, inner.merge(offset: 30 + "a.png".bytesize + 5) ])
    end

    def refused
      png = Z.page("a.png")
      {
        "no-images" => Z.build([ Z.page("notes.txt") ]),
        "only-hidden" => Z.build([ Z.page(".a.png") ]),
        "empty-page" => Z.build([ Z.page("a.png", "") ]),
        "page-over-32mib" => deflated_lie(32 * 1024 * 1024 + 1),
        "pages-over-2gib" => total_over_limit,
        "ambiguous-eocd" => Z.build([ png ], comment: Z.build([ png ])),
        "multiple-disks" => Z.build([ png ], eocd: { disk: 1 }),
        "directory-on-other-disk" => Z.build([ png ], eocd: { directory_disk: 1 }),
        "disk-entry-mismatch" => Z.build([ png ], eocd: { disk_entries: 2 }),
        "entry-disk-nonzero" => Z.build([ Z.page("a.png", disk: 1) ]),
        "zero-entries" => Z.build([]),
        "directory-offset-wrong" => Z.build([ png ], eocd: { directory_offset: 3 }),
        "directory-has-trailing-data" => Z.build([ png ], before_eocd: "extra"),
        "zip64-locator-before-eocd" => Z.build([ Z.page("a.png", file_comment: Z.zip64_locator) ]),
        "zip64-sentinel-size" => Z.build([ Z.page("a.png", central: { size: 0xffffffff }) ]),
        "zip64-sentinel-offset" => Z.build([ Z.page("a.png", offset: 0xffffffff) ]),
        "zip64-extra" => Z.build([ Z.page("a.png", central_extra: Z.extra(0x0001, "\0".b * 8)) ]),
        "too-many-entries" => many_pages(10_001),
        "name-too-long" => Z.build([ Z.page("#{'a' * 1021}.png") ]),
        "name-empty" => Z.build([ Z.page("") ]),
        "encrypted" => Z.build([ Z.page("a.png", central: { flags: 1 }, local: { flags: 1 }) ]),
        "strong-encryption" => Z.build([ Z.page("a.png", central: { flags: 0x40 }, local: { flags: 0x40 }) ]),
        "masked-headers" => Z.build([ Z.page("a.png", central: { flags: 0x2000 }, local: { flags: 0x2000 }) ]),
        "reserved-flag" => Z.build([ Z.page("a.png", central: { flags: 0x10 }, local: { flags: 0x10 }) ]),
        "bzip2-equal-sizes" => Z.build([ Z.page("a.png", "abc", method: 0, central: { method: 12 }, local: { method: 12 }) ]),
        "overlapping-with-consistent-headers" => overlapping_entries,
        "bzip2" => Z.build([ Z.page("a.png", central: { method: 12 }, local: { method: 12 }) ]),
        "stored-size-mismatch" => Z.build([ Z.page("a.png", "abc", method: 0, central: { compressed: 4 }, local: { compressed: 4 }) ]),
        "needed-version-too-new" => Z.build([ Z.page("a.png", central: { needed: 63 }, local: { needed: 63 }) ]),
        "unicode-path-extra" => Z.build([ Z.page("a.png", central_extra: Z.extra(0x7075, "\x01\0\0\0\0b.png".b)) ]),
        "aes-extra" => Z.build([ Z.page("a.png", central_extra: Z.extra(0x9901, "\x02\0AE\x03\0\0".b)) ]),
        "unicode-path-in-local-extra" => Z.build([ Z.page("a.png", local_extra: Z.extra(0x7075, "\x01\0\0\0\0b.png".b)) ]),
        "malformed-extra" => Z.build([ Z.page("a.png", central_extra: "\x01\x02\x03".b) ]),
        "extra-overruns" => Z.build([ Z.page("a.png", central_extra: [ 0xcafe, 9 ].pack("vv") + "ab") ]),
        "symlink" => Z.build([ Z.page("a.png", external: 0o120777 << 16) ]),
        "device" => Z.build([ Z.page("a.png", external: 0o020644 << 16) ]),
        "fifo" => Z.build([ Z.page("a.png", external: 0o010644 << 16) ]),
        "traversal" => Z.build([ Z.page("../a.png") ]),
        "traversal-middle" => Z.build([ Z.page("a/../b.png") ]),
        "absolute" => Z.build([ Z.page("/a.png") ]),
        "backslash" => Z.build([ Z.page("a\\b.png") ]),
        "drive" => Z.build([ Z.page("C:a.png") ]),
        "dot-part" => Z.build([ Z.page("./a.png") ]),
        "empty-part" => Z.build([ Z.page("a//b.png") ]),
        "control-character" => Z.build([ Z.page("a\u0001.png") ]),
        "delete-character" => Z.build([ Z.page("a\u007f.png") ]),
        "nul-character" => Z.build([ Z.page("a\0.png") ]),
        "duplicate" => Z.build([ Z.page("a.png"), Z.page("a.png") ]),
        "duplicate-nfc" => Z.build([ Z.page("é.png"), Z.page("é.png") ]),
        "duplicate-nfc-hangul" => Z.build([ Z.page("한.png"), Z.page("한.png") ]),
        "legacy-code-page-name" => Z.build([ Z.page("caf\xe9.png".b, flags: 0) ]),
        "invalid-utf8-flagged" => Z.build([ Z.page("caf\xe9.png".b, flags: Z::UTF8) ]),
        "overlong-utf8" => Z.build([ Z.page("\xc0\xaf.png".b, flags: Z::UTF8) ]),
        "folder-with-data" => Z.build([ { name: "dir/", data: "x", method: 0 }, png ]),
        "local-name-differs" => Z.build([ Z.page("a.png", local: { name: "b.png".b }) ]),
        "local-flags-differ" => Z.build([ Z.page("a.png", local: { flags: Z::UTF8 }) ]),
        "local-method-differs" => Z.build([ Z.page("a.png", local: { method: 0 }) ]),
        "local-crc-differs" => Z.build([ Z.page("a.png", local: { crc: 1 }) ]),
        "local-size-differs" => Z.build([ Z.page("a.png", local: { size: 1 }) ]),
        "local-compressed-differs" => Z.build([ Z.page("a.png", local: { compressed: 1 }) ]),
        "local-signature-wrong" => Z.build([ png ]).sub("PK\x03\x04".b, "PK\x03\x05".b),
        "descriptor-local-sizes-nonzero-wrong" => Z.build([ Z.page("a.png", flags: Z::DESCRIPTOR, local_sizes: true, local: { crc: 5, compressed: 6, size: 7 }) ]),
        "descriptor-extends-into-directory" => Z.build([ Z.page("a.png", flags: Z::DESCRIPTOR, no_descriptor: true) ]),
        "entry-extends-into-directory" => Z.build([ Z.page("a.png", central: { compressed: 100 }, local: { compressed: 100 }) ]),
        "offset-past-end" => Z.build([ Z.page("a.png", offset: 100_000) ]),
        "offset-inside-data" => Z.build([ Z.page("a.png"), Z.page("b.png", offset: 5) ]),
        "overlapping" => Z.build([ Z.page("a.png"), Z.page("b.png", offset: 0, local: { name: "b.png".b }) ]),
        "same-offset" => Z.build([ Z.page("a.png"), Z.page("b.png", offset: 0) ]),
        "central-signature-wrong" => Z.build([ png ]).sub("PK\x01\x02".b, "PK\x01\x03".b),
        "directory-size-too-small" => Z.build([ png ], eocd: { directory_size: 40 }),
        "directory-over-2mib" => Z.build(Array.new(2200) { |index| Z.page("#{'d' * 900}#{index}.png", "x", method: 0) }),
        "too-small" => "PK\x05\x06".b,
        "empty-file" => "".b,
        "plain-text" => "not a zip archive at all ".b * 4,
        "jpeg-bytes" => "\xff\xd8\xff\xe0".b + "x".b * 100,
        "eocd-comment-short" => Z.build([ png ]).then { |bytes| bytes[0...-2] + [ 40 ].pack("v") },
        "truncated-archive" => Z.build([ png ])[0...-5]
      }
    end

    def valid
      png = Z.page("a.png")
      {
        "natural" => natural_pages,
        "simple-deflated" => simple_pages(3),
        "simple-stored" => simple_pages(4, method: 0),
        "one-page" => Z.build([ png ]),
        "ten-thousand-pages" => many_pages(10_000),
        "archive-comment" => Z.build([ png ], comment: "trailing comment"),
        "comment-and-extras" => Z.build([ Z.page("a.png", central_extra: Z.extra(0xcafe, "1234"), local_extra: Z.extra(0xbeef, "56"), file_comment: "note") ], comment: "archive comment"),
        "windows-made-by" => Z.build([ Z.page("a.png", made_by: 0x0a14, external: 0x20) ]),
        "utf8-flag-ascii-name" => Z.build([ Z.page("a.png", flags: Z::UTF8) ]),
        "descriptor" => Z.build([ Z.page("a.png", flags: Z::DESCRIPTOR) ]),
        "directories-only-around" => Z.build([ { name: "a/", data: "", method: 0, external: Z::DIRECTORY }, Z.page("a/b.png") ]),
        "eocd-signature-in-data" => Z.build([ Z.page("a.png", "PK\x05\x06".b * 40, method: 0) ]),
        "unicode-names" => Z.build([ Z.page("é/ü.png"), Z.page("日本/語.jpeg"), Z.page("emoji 😀.webp") ]),
        "case-sensitive-names" => Z.build([ Z.page("A.png"), Z.page("a.png") ]),
        "nfc-distinct-by-case" => Z.build([ Z.page("É.png"), Z.page("é.png") ])
      }
    end

    def write_all(directory)
      FileUtils.mkdir_p(directory)
      (valid.merge(refused.transform_keys { |name| "refused-#{name}" })).each { |name, bytes| File.binwrite(File.join(directory, "#{name}.cbz"), bytes) }
    end
  end
end
