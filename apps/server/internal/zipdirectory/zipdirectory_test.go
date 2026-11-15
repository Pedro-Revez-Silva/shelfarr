package zipdirectory

import (
	"bytes"
	"context"
	"errors"
	"io"
	"strings"
	"testing"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/ziptest"
)

func read(data []byte) ([]Entry, error) {
	return Entries(context.Background(), bytes.NewReader(data), int64(len(data)))
}

func png() ziptest.Entry { return ziptest.Page("a.png") }

func TestAnArchiveYieldsEveryDirectoryFieldAndTheDataOffset(t *testing.T) {
	stored := ziptest.Raw("b/c.png", []byte("stored bytes"), ziptest.Stored)
	folder := ziptest.Entry{Name: "b/", Method: ziptest.Stored, External: ziptest.U32(ziptest.Directory)}
	deferred := ziptest.Page("d.png")
	deferred.Flags = ziptest.U16(ziptest.Descriptor)
	entries, err := read(ziptest.Build([]ziptest.Entry{png(), folder, stored, deferred}, ziptest.End{Comment: []byte("note")}))
	if err != nil || len(entries) != 4 {
		t.Fatalf("%v %v", entries, err)
	}
	first := entries[0]
	if first.Name != "a.png" || first.Method != Deflated || first.Offset != 0 || first.Directory || first.Size != 63 || first.DataOffset != 30+int64(len("a.png")) {
		t.Fatalf("%+v", first)
	}
	if !entries[1].Directory || entries[1].Name != "b/" || entries[1].Size != 0 {
		t.Fatalf("%+v", entries[1])
	}
	if entries[2].Method != Stored || entries[2].CompressedSize != 12 || entries[2].Size != 12 || entries[2].CRC != 0x6a63d6c1 && entries[2].CRC == 0 {
		t.Fatalf("%+v", entries[2])
	}
	if entries[3].Flags&ziptest.Descriptor == 0 || entries[3].Offset <= entries[2].Offset {
		t.Fatalf("%+v", entries[3])
	}
}

type refusal struct {
	name   string
	data   []byte
	reason string
}

func manyEntries(count int) []byte {
	entries := make([]ziptest.Entry, count)
	for index := range entries {
		entries[index] = ziptest.Raw(strings.Repeat("a", 6)+string(rune('a'+index%26))+string(rune('a'+index/26%26))+string(rune('a'+index/676%26))+string(rune('a'+index/17576%26))+".png", []byte("x"), ziptest.Stored)
	}
	return ziptest.Build(entries, ziptest.End{})
}

func refusals() []refusal {
	unsupported := "This archive uses unsupported ZIP features such as encryption or ZIP64"
	directory := "This archive's directory is unsupported or too large"
	headers := "This archive's entry headers disagree with its directory"
	unsafe := "This archive contains an unsafe name"
	withFlags := func(flags uint16) ziptest.Entry {
		entry := png()
		entry.Central.Flags, entry.Local.Flags = ziptest.U16(flags), ziptest.U16(flags)
		return entry
	}
	build := func(entries ...ziptest.Entry) []byte { return ziptest.Build(entries, ziptest.End{}) }
	withEnd := func(end ziptest.End, entries ...ziptest.Entry) []byte { return ziptest.Build(entries, end) }
	special := func(external uint32) ziptest.Entry {
		entry := png()
		entry.External = ziptest.U32(external)
		return entry
	}
	method := func(code uint16) ziptest.Entry {
		entry := png()
		entry.Central.Method, entry.Local.Method = ziptest.U16(code), ziptest.U16(code)
		return entry
	}
	extra := func(central, local []byte) ziptest.Entry {
		entry := png()
		entry.CentralExtra, entry.LocalExtra = central, local
		return entry
	}
	local := func(header ziptest.Header) ziptest.Entry {
		entry := png()
		entry.Local = header
		return entry
	}
	named := func(name string) []byte { return build(ziptest.Page(name)) }
	deferredEntry := func(mutate func(*ziptest.Entry)) []byte {
		entry := png()
		entry.Flags = ziptest.U16(ziptest.Descriptor)
		mutate(&entry)
		return build(entry)
	}
	hidden := ziptest.Build([]ziptest.Entry{png()}, ziptest.End{})
	zip64Locator := ziptest.Extra(0, nil)[:0]
	locator := make([]byte, 20)
	copy(locator, "PK\x06\x07")
	zip64Locator = locator
	commentLocator := png()
	commentLocator.FileComment = zip64Locator
	return []refusal{
		{"empty file", nil, "This archive is too small"},
		{"shorter than a directory record", []byte("PK\x05\x06"), "This archive is too small"},
		{"plain text", bytes.Repeat([]byte("not a zip archive at all "), 4), "This archive has no unambiguous ZIP directory"},
		{"a second record hidden in the comment", withEnd(ziptest.End{Comment: hidden}, png()), "This archive has no unambiguous ZIP directory"},
		{"a comment that does not reach the end", append(build(png())[:len(build(png()))-2], 40, 0), "This archive has no unambiguous ZIP directory"},
		{"a second disk", withEnd(ziptest.End{Disk: ziptest.U16(1)}, png()), directory},
		{"a directory on another disk", withEnd(ziptest.End{DirectoryDisk: ziptest.U16(1)}, png()), directory},
		{"disk and total counts that differ", withEnd(ziptest.End{DiskEntries: ziptest.U16(2)}, png()), directory},
		{"no entries", build(), directory},
		{"a directory that starts elsewhere", withEnd(ziptest.End{DirectoryOffset: ziptest.U32(3)}, png()), directory},
		{"data between the directory and its record", withEnd(ziptest.End{BeforeEnd: []byte("extra")}, png()), directory},
		{"a directory smaller than its entries", withEnd(ziptest.End{DirectorySize: ziptest.U32(40)}, png()), directory},
		{"more than ten thousand entries", manyEntries(MaxEntries + 1), directory},
		{"a directory over two mebibytes", func() []byte {
			entries := make([]ziptest.Entry, 2200)
			for index := range entries {
				entries[index] = ziptest.Raw(strings.Repeat("d", 940)+string(rune('a'+index%26))+string(rune('a'+index/26%26))+string(rune('a'+index/676))+".png", []byte("x"), ziptest.Stored)
			}
			return build(entries...)
		}(), directory},
		{"a ZIP64 locator before the record", build(commentLocator), "ZIP64 archives are not supported"},
		{"a ZIP64 size sentinel", build(func() ziptest.Entry {
			entry := png()
			entry.Central.Size = ziptest.U32(0xffffffff)
			return entry
		}()), unsupported},
		{"a ZIP64 offset sentinel", build(func() ziptest.Entry {
			entry := png()
			entry.Offset = ziptest.U32(0xffffffff)
			return entry
		}()), unsupported},
		{"a ZIP64 extra field", build(extra(ziptest.Extra(0x0001, make([]byte, 8)), nil)), unsupported},
		{"a Unicode path override", build(extra(ziptest.Extra(0x7075, []byte{1, 0, 0, 0, 0, 'b'}), nil)), unsupported},
		{"an AES extra field", build(extra(ziptest.Extra(0x9901, []byte{2, 0, 'A', 'E', 3, 0, 0}), nil)), unsupported},
		{"a malformed extra field", build(extra([]byte{1, 2, 3}, nil)), unsupported},
		{"an extra field that overruns", build(extra(append(ziptest.Extra(0xcafe, []byte("ab"))[:4], 'a', 'b', 9, 0), nil)), unsupported},
		{"a Unicode path override in the local header", build(extra(nil, ziptest.Extra(0x7075, []byte{1, 0, 0, 0, 0, 'b'}))), headers},
		{"encryption", build(withFlags(0x0001)), unsupported},
		{"strong encryption", build(withFlags(0x0040)), unsupported},
		{"masked headers", build(withFlags(0x2000)), unsupported},
		{"a reserved flag", build(withFlags(0x0010)), unsupported},
		{"bzip2", build(method(12)), unsupported},
		{"bzip2 with equal sizes", build(func() ziptest.Entry {
			entry := ziptest.Raw("a.png", []byte("abc"), ziptest.Stored)
			entry.Central.Method, entry.Local.Method = ziptest.U16(12), ziptest.U16(12)
			return entry
		}()), unsupported},
		{"a stored entry whose sizes differ", build(func() ziptest.Entry {
			entry := ziptest.Raw("a.png", []byte("abc"), ziptest.Stored)
			entry.Central.Compressed, entry.Local.Compressed = ziptest.U32(4), ziptest.U32(4)
			return entry
		}()), unsupported},
		{"a version that is too new", build(func() ziptest.Entry {
			entry := png()
			entry.Central.Needed, entry.Local.Needed = ziptest.U16(63), ziptest.U16(63)
			return entry
		}()), unsupported},
		{"a second disk number in an entry", build(func() ziptest.Entry {
			entry := png()
			entry.Disk = 1
			return entry
		}()), unsupported},
		{"a symbolic link", build(special(0o120777 << 16)), "This archive contains a link or special file"},
		{"a device", build(special(0o020644 << 16)), "This archive contains a link or special file"},
		{"a pipe", build(special(0o010644 << 16)), "This archive contains a link or special file"},
		{"a parent directory", named("../a.png"), unsafe},
		{"a parent directory in the middle", named("a/../b.png"), unsafe},
		{"an absolute path", named("/a.png"), unsafe},
		{"a backslash", named("a\\b.png"), unsafe},
		{"a drive", named("C:a.png"), unsafe},
		{"a dot segment", named("./a.png"), unsafe},
		{"an empty segment", named("a//b.png"), unsafe},
		{"a control character", named("a\x01.png"), unsafe},
		{"a delete character", named("a\x7f.png"), unsafe},
		{"a NUL character", named("a\x00.png"), unsafe},
		{"an empty name", named(""), "This archive contains an unsupported name"},
		{"a name over 1024 bytes", named(strings.Repeat("a", 1021) + ".png"), "This archive contains an unsupported name"},
		{"duplicate names", build(png(), png()), "This archive contains duplicate names"},
		{"names equal after composition", build(ziptest.Page("é.png"), ziptest.Page("é.png")), "This archive contains duplicate names"},
		{"names equal after Hangul composition", build(ziptest.Page("한.png"), ziptest.Page("한.png")), "This archive contains duplicate names"},
		{"a legacy code page name", build(func() ziptest.Entry {
			entry := ziptest.Page("caf\xe9.png")
			entry.Flags = ziptest.U16(0)
			return entry
		}()), "This archive's names need UTF-8"},
		{"an invalid flagged UTF-8 name", build(func() ziptest.Entry {
			entry := ziptest.Page("caf\xe9.png")
			entry.Flags = ziptest.U16(ziptest.UTF8Flag)
			return entry
		}()), "This archive contains a name that isn't valid UTF-8"},
		{"an overlong UTF-8 name", build(func() ziptest.Entry {
			entry := ziptest.Page("\xc0\xaf.png")
			entry.Flags = ziptest.U16(ziptest.UTF8Flag)
			return entry
		}()), "This archive contains a name that isn't valid UTF-8"},
		{"a folder with data", build(ziptest.Raw("dir/", []byte("x"), ziptest.Stored), png()), "This archive contains a folder with data"},
		{"a local name that differs", build(local(ziptest.Header{Name: ziptest.Str("b.png")})), headers},
		{"local flags that differ", build(local(ziptest.Header{Flags: ziptest.U16(ziptest.UTF8Flag)})), headers},
		{"a local method that differs", build(local(ziptest.Header{Method: ziptest.U16(0)})), headers},
		{"a local CRC that differs", build(local(ziptest.Header{CRC: ziptest.U32(1)})), headers},
		{"a local size that differs", build(local(ziptest.Header{Size: ziptest.U32(1)})), headers},
		{"a local compressed size that differs", build(local(ziptest.Header{Compressed: ziptest.U32(1)})), headers},
		{"a wrong local signature", bytes.Replace(build(png()), []byte("PK\x03\x04"), []byte("PK\x03\x05"), 1), headers},
		{"a wrong central signature", bytes.Replace(build(png()), []byte("PK\x01\x02"), []byte("PK\x01\x03"), 1), "This archive's directory is damaged"},
		{"descriptor sizes that are neither zero nor the directory's", deferredEntry(func(entry *ziptest.Entry) {
			entry.LocalSizes = true
			entry.Local = ziptest.Header{CRC: ziptest.U32(5), Compressed: ziptest.U32(6), Size: ziptest.U32(7)}
		}), headers},
		{"a descriptor that runs into the directory", deferredEntry(func(entry *ziptest.Entry) { entry.NoDescriptor = true }), "This archive's entries extend into its directory"},
		{"data that runs into the directory", build(func() ziptest.Entry {
			entry := png()
			entry.Central.Compressed, entry.Local.Compressed = ziptest.U32(100), ziptest.U32(100)
			return entry
		}()), "This archive's entries extend into its directory"},
		{"an offset past the end", build(func() ziptest.Entry {
			entry := png()
			entry.Offset = ziptest.U32(100_000)
			return entry
		}()), "This archive is truncated"},
		{"an offset inside another entry's data", build(png(), func() ziptest.Entry {
			entry := ziptest.Page("b.png")
			entry.Offset = ziptest.U32(5)
			return entry
		}()), headers},
		{"two entries at one offset", build(png(), func() ziptest.Entry {
			entry := ziptest.Page("b.png")
			entry.Offset = ziptest.U32(0)
			return entry
		}()), headers},
		{"a truncated archive", build(png())[:len(build(png()))-5], "This archive has no unambiguous ZIP directory"},
	}
}

func TestEveryUnsafeOrUnsupportedArchiveIsRefusedWithItsReason(t *testing.T) {
	for _, test := range refusals() {
		entries, err := read(test.data)
		var invalid Invalid
		if !errors.As(err, &invalid) || invalid.Reason != test.reason || entries != nil {
			t.Errorf("%s: %d entries, error %v, want %q", test.name, len(entries), err, test.reason)
		}
	}
}

func TestEntriesWhoseExtentsShareBytesAreRefusedEvenWithConsistentHeaders(t *testing.T) {
	inner := ziptest.Raw("b.png", []byte("inner image"), ziptest.Stored)
	standalone := ziptest.Build([]ziptest.Entry{inner}, ziptest.End{})
	embedded := standalone[:30+len("b.png")+len("inner image")]
	outer := ziptest.Raw("a.png", append([]byte("12345"), embedded...), ziptest.Stored)
	innerOffset := uint32(30 + len("a.png") + 5)
	inner.Offset = ziptest.U32(innerOffset)
	var invalid Invalid
	if _, err := read(ziptest.Build([]ziptest.Entry{outer, inner}, ziptest.End{})); !errors.As(err, &invalid) || invalid.Reason != "This archive's entries overlap" {
		t.Fatalf("%v", err)
	}
	separate := ziptest.Raw("c.png", []byte("separate"), ziptest.Stored)
	if entries, err := read(ziptest.Build([]ziptest.Entry{outer, separate}, ziptest.End{})); err != nil || len(entries) != 2 {
		t.Fatalf("control: %v %v", entries, err)
	}
}

func TestADirectoryScanStopsWhenTheContextIsCancelled(t *testing.T) {
	data := manyEntries(100)
	source := reader{ctx: context.Background(), file: bytes.NewReader(data), size: int64(len(data))}
	_, count, directory, err := source.centralDirectory()
	if err != nil {
		t.Fatal(err)
	}
	cancelled, cancel := context.WithCancel(context.Background())
	cancel()
	if entries, err := parseDirectory(cancelled, directory, count); !errors.Is(err, context.Canceled) || entries != nil {
		t.Fatalf("%v", err)
	}
}

func TestTenThousandEntriesAreAccepted(t *testing.T) {
	entries, err := read(manyEntries(MaxEntries))
	if err != nil || len(entries) != MaxEntries {
		t.Fatalf("%d %v", len(entries), err)
	}
}

func TestACancelledContextStopsTheScan(t *testing.T) {
	data := manyEntries(MaxEntries)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := Entries(ctx, bytes.NewReader(data), int64(len(data))); !errors.Is(err, context.Canceled) {
		t.Fatalf("%v", err)
	}
	var cancelScan func()
	reads := 0
	counting := readerFunc(func(buffer []byte, offset int64) (int, error) {
		reads++
		if reads == 40 {
			cancelScan()
		}
		return bytes.NewReader(data).ReadAt(buffer, offset)
	})
	ctx2, cancelNow := context.WithCancel(context.Background())
	cancelScan = cancelNow
	if _, err := Entries(ctx2, counting, int64(len(data))); !errors.Is(err, context.Canceled) || reads > 60 {
		t.Fatalf("%v after %d reads", err, reads)
	}
}

type readerFunc func([]byte, int64) (int, error)

func (f readerFunc) ReadAt(buffer []byte, offset int64) (int, error) { return f(buffer, offset) }

func TestAReaderFailureIsAnInvalidArchiveNeverAnEmptyList(t *testing.T) {
	data := ziptest.Simple(3)
	failing := readerFunc(func(buffer []byte, offset int64) (int, error) { return 0, errors.New("input/output error") })
	var invalid Invalid
	if entries, err := Entries(context.Background(), failing, int64(len(data))); !errors.As(err, &invalid) || entries != nil {
		t.Fatalf("%v %v", entries, err)
	}
	short := readerFunc(func(buffer []byte, offset int64) (int, error) { return 0, io.EOF })
	if _, err := Entries(context.Background(), short, int64(len(data))); !errors.As(err, &invalid) {
		t.Fatalf("%v", err)
	}
}

func FuzzEntries(f *testing.F) {
	f.Add(ziptest.Simple(3))
	f.Add(ziptest.Build([]ziptest.Entry{ziptest.Raw("a/b.png", []byte("stored"), ziptest.Stored), {Name: "a/", Method: ziptest.Stored}}, ziptest.End{Comment: []byte("comment")}))
	for _, test := range refusals() {
		f.Add(test.data)
	}
	f.Fuzz(func(t *testing.T, data []byte) {
		entries, err := read(data)
		if err != nil {
			if entries != nil {
				t.Fatal("entries returned with an error")
			}
			return
		}
		if len(entries) < 1 || len(entries) > MaxEntries {
			t.Fatalf("%d entries", len(entries))
		}
		seen := map[string]bool{}
		for _, entry := range entries {
			if entry.DataOffset+entry.CompressedSize > int64(len(data)) || entry.Offset < 0 || len(entry.Name) < 1 || len(entry.Name) > MaxNameBytes || seen[entry.Name] {
				t.Fatalf("%+v", entry)
			}
			seen[entry.Name] = true
		}
	})
}
