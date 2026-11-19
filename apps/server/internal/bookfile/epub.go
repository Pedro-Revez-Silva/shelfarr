package bookfile

import (
	"context"
	"errors"
	"hash/crc32"
	"io"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/zipdirectory"
)

const (
	epubMediaType = "application/epub+zip"
	mimetypeEntry = "mimetype"
	containerName = "META-INF/container.xml"
)

var ErrNotEPUB = errors.New("not an EPUB container")

func CheckEPUB(ctx context.Context, file io.ReaderAt, size int64) error {
	entries, err := zipdirectory.Entries(ctx, file, size)
	var archive zipdirectory.Invalid
	if errors.As(err, &archive) {
		return ErrNotEPUB
	}
	if err != nil {
		return err
	}
	if len(entries) == 0 {
		return ErrNotEPUB
	}
	first := entries[0]
	if first.Name != mimetypeEntry || first.Offset != 0 || first.Method != zipdirectory.Stored || first.Size != int64(len(epubMediaType)) {
		return ErrNotEPUB
	}
	declared := make([]byte, len(epubMediaType))
	if _, err := file.ReadAt(declared, first.DataOffset); err != nil || string(declared) != epubMediaType || crc32.ChecksumIEEE(declared) != first.CRC {
		return ErrNotEPUB
	}
	for _, entry := range entries[1:] {
		if entry.Name == containerName && !entry.Directory && entry.Size > 0 {
			return nil
		}
	}
	return ErrNotEPUB
}
