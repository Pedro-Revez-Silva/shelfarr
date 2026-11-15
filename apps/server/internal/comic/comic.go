package comic

import (
	"context"
	"errors"
	"fmt"
	"io"
	"path"
	"slices"
	"strings"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/naturalorder"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/zipdirectory"
)

const (
	MaxMetadataBytes        = 8 << 20
	MaxImageBytes           = 32 << 20
	MaxCompressedImageBytes = MaxImageBytes + 64<<10
	MaxTotalBytes           = 2 << 30
	itemOverhead            = 220
)

var imageTypes = map[string]string{"jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "webp": "image/webp"}

type Invalid struct{ Reason string }

func (e Invalid) Error() string { return e.Reason }

type Page struct {
	Position          int    `json:"position"`
	Href              string `json:"href"`
	MediaType         string `json:"media_type"`
	SizeBytes         int64  `json:"size_bytes"`
	CompressedSize    int64  `json:"compressed_size"`
	CompressionMethod int    `json:"compression_method"`
	LocalHeaderOffset int64  `json:"local_header_offset"`
	CRC32             string `json:"crc32"`
}

type candidate struct {
	entry     zipdirectory.Entry
	href      string
	mediaType string
	key       naturalorder.Key
}

func Pages(ctx context.Context, file io.ReaderAt, size int64) ([]Page, error) {
	entries, err := zipdirectory.Entries(ctx, file, size)
	var archive zipdirectory.Invalid
	if errors.As(err, &archive) {
		return nil, Invalid{archive.Reason}
	}
	if err != nil {
		return nil, err
	}
	var candidates []candidate
	var total, metadata int64
	for _, entry := range entries {
		if entry.Directory || hidden(entry.Name) {
			continue
		}
		mediaType, supported := imageTypes[extension(entry.Name)]
		if !supported {
			continue
		}
		if entry.Size < 1 || entry.Size > MaxImageBytes {
			return nil, Invalid{"A comic page exceeds 32 MiB"}
		}
		if entry.CompressedSize < 1 || entry.CompressedSize > MaxCompressedImageBytes {
			return nil, Invalid{"A comic page exceeds the safe compressed download limit"}
		}
		total += entry.Size
		if total > MaxTotalBytes {
			return nil, Invalid{"Comic pages exceed 2 GiB"}
		}
		href := escape(entry.Name)
		metadata += int64(len(href)) + itemOverhead
		if metadata > MaxMetadataBytes {
			return nil, Invalid{"This comic's page list is too large"}
		}
		candidates = append(candidates, candidate{entry: entry, href: href, mediaType: mediaType, key: naturalorder.KeyOf(entry.Name)})
	}
	if len(candidates) == 0 {
		return nil, Invalid{"This comic contains no supported image pages"}
	}
	slices.SortFunc(candidates, func(left, right candidate) int {
		if order := naturalorder.Compare(left.key, right.key); order != 0 {
			return order
		}
		return strings.Compare(left.entry.Name, right.entry.Name)
	})
	pages := make([]Page, len(candidates))
	for index, found := range candidates {
		pages[index] = Page{
			Position: index + 1, Href: found.href, MediaType: found.mediaType, SizeBytes: found.entry.Size, CompressedSize: found.entry.CompressedSize,
			CompressionMethod: int(found.entry.Method), LocalHeaderOffset: found.entry.Offset, CRC32: fmt.Sprintf("%08x", found.entry.CRC),
		}
	}
	return pages, nil
}

func hidden(name string) bool {
	return slices.ContainsFunc(strings.Split(name, "/"), func(part string) bool { return strings.HasPrefix(part, ".") || part == "__MACOSX" })
}

func extension(name string) string {
	base := path.Base(name)
	trimmed := strings.TrimLeft(base, ".")
	index := strings.LastIndex(trimmed, ".")
	if index < 0 {
		return ""
	}
	return strings.ToLower(trimmed[index+1:])
}

func escape(name string) string {
	var builder strings.Builder
	for index := 0; index < len(name); index++ {
		value := name[index]
		if value >= 'A' && value <= 'Z' || value >= 'a' && value <= 'z' || value >= '0' && value <= '9' || strings.IndexByte("-._~/", value) >= 0 {
			builder.WriteByte(value)
		} else {
			fmt.Fprintf(&builder, "%%%02X", value)
		}
	}
	return builder.String()
}
