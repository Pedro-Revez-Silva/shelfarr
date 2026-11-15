package comic

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"hash/crc32"
	"math/rand"
	"reflect"
	"testing"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/ziptest"
)

func pages(data []byte) ([]Page, error) {
	return Pages(context.Background(), bytes.NewReader(data), int64(len(data)))
}

func archive(entries ...ziptest.Entry) []byte { return ziptest.Build(entries, ziptest.End{}) }

func TestPagesCarryTheExactDirectoryMetadataInReadingOrder(t *testing.T) {
	second := ziptest.Raw("Page 2.PNG", []byte("second image"), ziptest.Stored)
	tenth := ziptest.Raw("page 10.webp", []byte("tenth"), ziptest.Stored)
	first := ziptest.Page("Page 1.jpeg")
	got, err := pages(archive(tenth, second, first))
	if err != nil {
		t.Fatal(err)
	}
	checksum := func(text string) string { return fmt.Sprintf("%08x", crc32.ChecksumIEEE([]byte(text))) }
	want := []Page{
		{Position: 1, Href: "Page%201.jpeg", MediaType: "image/jpeg", SizeBytes: 81, CompressedSize: got[0].CompressedSize, CompressionMethod: 8, LocalHeaderOffset: got[0].LocalHeaderOffset, CRC32: got[0].CRC32},
		{Position: 2, Href: "Page%202.PNG", MediaType: "image/png", SizeBytes: 12, CompressedSize: 12, CompressionMethod: 0, LocalHeaderOffset: got[1].LocalHeaderOffset, CRC32: checksum("second image")},
		{Position: 3, Href: "page%2010.webp", MediaType: "image/webp", SizeBytes: 5, CompressedSize: 5, CompressionMethod: 0, LocalHeaderOffset: 0, CRC32: checksum("tenth")},
	}
	if !reflect.DeepEqual(got, want) || got[1].LocalHeaderOffset <= got[2].LocalHeaderOffset || got[0].LocalHeaderOffset <= got[1].LocalHeaderOffset {
		t.Fatalf("%+v", got)
	}
}

func TestOnlyVisibleSupportedImagesArePages(t *testing.T) {
	entries := []ziptest.Entry{
		ziptest.Page("keep.png"), ziptest.Page("notes.txt"), ziptest.Page("a.gif"), ziptest.Page("a.png.txt"), ziptest.Page("noextension"), ziptest.Page(".hidden.png"), ziptest.Page("dir/.hidden.png"),
		ziptest.Page("__MACOSX/a.png"), ziptest.Page("dir/__MACOSX/a.png"), ziptest.Page("._a.png"), ziptest.Page(".dir/a.png"), ziptest.Page("Cover.JPEG"), ziptest.Page("sub/p.WebP"),
		{Name: "folder/", Method: ziptest.Stored, External: ziptest.U32(ziptest.Directory)},
	}
	got, err := pages(archive(entries...))
	if err != nil {
		t.Fatal(err)
	}
	var hrefs []string
	for _, page := range got {
		hrefs = append(hrefs, page.Href)
	}
	if want := []string{"Cover.JPEG", "keep.png", "sub/p.WebP"}; !reflect.DeepEqual(hrefs, want) {
		t.Fatalf("%v", hrefs)
	}
}

func TestHrefsEscapeEveryByteOutsideTheUnreservedSet(t *testing.T) {
	got, err := pages(archive(ziptest.Page("a b+c%d é;#?日.png")))
	if err != nil || got[0].Href != "a%20b%2Bc%25d%20%C3%A9%3B%23%3F%E6%97%A5.png" {
		t.Fatalf("%+v %v", got, err)
	}
	got, err = pages(archive(ziptest.Page("A-z_0.9~/x.png")))
	if err != nil || got[0].Href != "A-z_0.9~/x.png" {
		t.Fatalf("%+v %v", got, err)
	}
}

func TestOrderIsNaturalCaseInsensitiveAndBreaksTiesByTheExactName(t *testing.T) {
	names := []string{"p10.png", "P2.png", "p1.png", "p01.png", "P01.png", "p001.png", "q.png", "ch10/a.png", "CH2/a.png", "p99999999999999999999.png"}
	entries := make([]ziptest.Entry, len(names))
	for index, name := range names {
		entries[index] = ziptest.Page(name)
	}
	got, err := pages(archive(entries...))
	if err != nil {
		t.Fatal(err)
	}
	var order []string
	for _, page := range got {
		order = append(order, page.Href)
	}
	want := []string{"CH2/a.png", "ch10/a.png", "P01.png", "p001.png", "p01.png", "p1.png", "P2.png", "p10.png", "p99999999999999999999.png", "q.png"}
	if !reflect.DeepEqual(order, want) {
		t.Fatalf("%v", order)
	}
	for index, page := range got {
		if page.Position != index+1 {
			t.Fatalf("position %d at index %d", page.Position, index)
		}
	}
}

func lying(name string, size uint32) ziptest.Entry {
	entry := ziptest.Page(name)
	entry.Central.Size, entry.Local.Size = ziptest.U32(size), ziptest.U32(size)
	return entry
}

func TestPageSizeLimits(t *testing.T) {
	const mebibyte = 1 << 20
	if got, err := pages(archive(lying("a.png", 32*mebibyte))); err != nil || len(got) != 1 || got[0].SizeBytes != 32*mebibyte {
		t.Fatalf("32 MiB must be accepted: %v %v", got, err)
	}
	for name, entry := range map[string]ziptest.Entry{
		"one byte over 32 MiB": lying("a.png", 32*mebibyte+1),
		"an empty page":        ziptest.Raw("a.png", nil, ziptest.Stored),
		"a zero declared size": lying("a.png", 0),
	} {
		var invalid Invalid
		if _, err := pages(archive(entry)); !errors.As(err, &invalid) || invalid.Reason != "A comic page exceeds 32 MiB" {
			t.Errorf("%s: %v", name, err)
		}
	}
}

func TestCompressedPageLimit(t *testing.T) {
	random := make([]byte, 32<<20+64<<10+4096)
	rand.New(rand.NewSource(7)).Read(random)
	entry := ziptest.Entry{Name: "a.png", Data: random, Method: ziptest.Deflated}
	entry.Central.Size, entry.Local.Size = ziptest.U32(1000), ziptest.U32(1000)
	var invalid Invalid
	if _, err := pages(archive(entry)); !errors.As(err, &invalid) || invalid.Reason != "A comic page exceeds the safe compressed download limit" {
		t.Fatalf("%v", err)
	}
	entry = ziptest.Entry{Name: "a.png", Data: random[:1<<20], Method: ziptest.Deflated}
	if got, err := pages(archive(entry)); err != nil || len(got) != 1 {
		t.Fatalf("a large page inside the limit: %v", err)
	}
}

func TestTotalSizeLimit(t *testing.T) {
	build := func(count int) []byte {
		entries := make([]ziptest.Entry, count)
		for index := range entries {
			entries[index] = lying(fmt.Sprintf("%02d.png", index), 32<<20)
		}
		return archive(entries...)
	}
	if got, err := pages(build(64)); err != nil || len(got) != 64 {
		t.Fatalf("exactly 2 GiB must be accepted: %v", err)
	}
	var invalid Invalid
	if _, err := pages(build(65)); !errors.As(err, &invalid) || invalid.Reason != "Comic pages exceed 2 GiB" {
		t.Fatalf("%v", err)
	}
}

func TestAnArchiveWithoutPagesOrWithAnUnsafeStructureIsInvalidNeverEmpty(t *testing.T) {
	for name, data := range map[string][]byte{
		"only text":   archive(ziptest.Page("notes.txt")),
		"only hidden": archive(ziptest.Page(".a.png")),
		"not a zip":   []byte("plain text, not a comic archive at all"),
		"empty":       nil,
		"traversal":   archive(ziptest.Page("../a.png")),
	} {
		got, err := pages(data)
		var invalid Invalid
		if !errors.As(err, &invalid) || got != nil {
			t.Errorf("%s: %v %v", name, got, err)
		}
	}
	var invalid Invalid
	if _, err := pages(archive(ziptest.Page("notes.txt"))); !errors.As(err, &invalid) || invalid.Reason != "This comic contains no supported image pages" {
		t.Fatalf("%v", err)
	}
}

func TestACancelledScanIsNotAnInvalidArchive(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	data := ziptest.Simple(3)
	_, err := Pages(ctx, bytes.NewReader(data), int64(len(data)))
	var invalid Invalid
	if !errors.Is(err, context.Canceled) || errors.As(err, &invalid) {
		t.Fatalf("%v", err)
	}
}
