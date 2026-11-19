package bookfile

import (
	"bytes"
	"compress/flate"
	"context"
	"encoding/xml"
	"errors"
	"hash/crc32"
	"io"
	"net/url"
	"path"
	"strings"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/zipdirectory"
)

const (
	maxContainerBytes = 64 << 10
	maxPackageBytes   = 1 << 20
)

var ErrUnreadableEPUB = errors.New("EPUB has no readable package")

type containerDocument struct {
	Rootfiles []struct {
		FullPath  string `xml:"full-path,attr"`
		MediaType string `xml:"media-type,attr"`
	} `xml:"rootfiles>rootfile"`
}

type packageDocument struct {
	Items []struct {
		ID   string `xml:"id,attr"`
		Href string `xml:"href,attr"`
	} `xml:"manifest>item"`
	Spine []struct {
		IDRef string `xml:"idref,attr"`
	} `xml:"spine>itemref"`
}

func CheckReadableEPUB(ctx context.Context, file io.ReaderAt, size int64) error {
	if err := CheckEPUB(ctx, file, size); err != nil {
		return err
	}
	entries, err := zipdirectory.Entries(ctx, file, size)
	if err != nil {
		return ErrNotEPUB
	}
	byName := map[string]zipdirectory.Entry{}
	for _, entry := range entries {
		if !entry.Directory {
			byName[entry.Name] = entry
		}
	}
	var container containerDocument
	if err := decodeEntry(file, byName[containerName], maxContainerBytes, &container); err != nil {
		return ErrUnreadableEPUB
	}
	packagePath := ""
	for _, rootfile := range container.Rootfiles {
		if rootfile.MediaType == "application/oebps-package+xml" {
			packagePath = rootfile.FullPath
			break
		}
	}
	packageEntry, found := byName[packagePath]
	if packagePath == "" || !found {
		return ErrUnreadableEPUB
	}
	var opf packageDocument
	if err := decodeEntry(file, packageEntry, maxPackageBytes, &opf); err != nil {
		return ErrUnreadableEPUB
	}
	hrefs := map[string]string{}
	for _, item := range opf.Items {
		hrefs[item.ID] = item.Href
	}
	for _, itemref := range opf.Spine {
		if document, ok := resolve(path.Dir(packagePath), hrefs[itemref.IDRef]); ok {
			if _, present := byName[document]; present {
				return nil
			}
		}
	}
	return ErrUnreadableEPUB
}

func resolve(base, href string) (string, bool) {
	if href == "" {
		return "", false
	}
	parsed, err := url.Parse(href)
	if err != nil || parsed.Scheme != "" || parsed.Host != "" || strings.HasPrefix(parsed.Path, "/") {
		return "", false
	}
	joined := path.Clean(path.Join(base, parsed.Path))
	if joined == "." || strings.HasPrefix(joined, "../") || joined == ".." {
		return "", false
	}
	return joined, true
}

func decodeEntry(file io.ReaderAt, entry zipdirectory.Entry, limit int64, target any) error {
	if entry.Name == "" || entry.Size <= 0 || entry.Size > limit || entry.CompressedSize > limit {
		return ErrUnreadableEPUB
	}
	section := io.NewSectionReader(file, entry.DataOffset, entry.CompressedSize)
	var source io.Reader = section
	switch entry.Method {
	case zipdirectory.Stored:
	case zipdirectory.Deflated:
		inflater := flate.NewReader(section)
		defer inflater.Close()
		source = inflater
	default:
		return ErrUnreadableEPUB
	}
	data, err := io.ReadAll(io.LimitReader(source, limit+1))
	if err != nil || int64(len(data)) != entry.Size || crc32.ChecksumIEEE(data) != entry.CRC {
		return ErrUnreadableEPUB
	}
	decoder := xml.NewDecoder(bytes.NewReader(data))
	decoder.Strict = true
	decoder.Entity = map[string]string{}
	return decoder.Decode(target)
}
