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
	"slices"
	"strings"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/zipdirectory"
)

const (
	maxContainerBytes  = 64 << 10
	maxPackageBytes    = 1 << 20
	maxNavigationBytes = 1 << 20
	ncxMediaType       = "application/x-dtbncx+xml"
)

var ErrUnreadableEPUB = errors.New("EPUB has no readable package")

type manifestItem struct {
	href       string
	mediaType  string
	properties []string
}

type openedPackage struct {
	hasPackage  bool
	hasMetadata bool
	hasManifest bool
	hasSpine    bool
	items       map[string]manifestItem
	itemOrder   []string
	spine       []string
	spineTOC    string
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
	container, err := readEntry(file, byName[containerName], maxContainerBytes)
	if err != nil {
		return ErrUnreadableEPUB
	}
	packagePath, err := firstRootfile(container)
	if err != nil {
		return ErrUnreadableEPUB
	}
	document, err := readEntry(file, byName[packagePath], maxPackageBytes)
	if err != nil {
		return ErrUnreadableEPUB
	}
	opened, err := scanPackage(document)
	if err != nil || !opened.hasPackage || !opened.hasMetadata || !opened.hasManifest || !opened.hasSpine || len(opened.spine) == 0 {
		return ErrUnreadableEPUB
	}
	base := path.Dir(packagePath)
	if !present(byName, base, opened.items[opened.spine[0]].href) {
		return ErrUnreadableEPUB
	}
	if navigation := opened.navigationHref(); navigation != "" {
		name, ok := resolve(base, navigation)
		if !ok {
			return ErrUnreadableEPUB
		}
		data, err := readEntry(file, byName[name], maxNavigationBytes)
		if err != nil || wellFormed(data) != nil {
			return ErrUnreadableEPUB
		}
	}
	return nil
}

func (p openedPackage) navigationHref() string {
	for _, id := range p.itemOrder {
		if slices.Contains(p.items[id].properties, "nav") {
			return p.items[id].href
		}
	}
	for _, id := range p.itemOrder {
		if p.items[id].mediaType == ncxMediaType {
			return p.items[id].href
		}
	}
	if p.spineTOC != "" {
		return p.items[p.spineTOC].href
	}
	return ""
}

func present(byName map[string]zipdirectory.Entry, base, href string) bool {
	name, ok := resolve(base, href)
	if !ok {
		return false
	}
	_, found := byName[name]
	return found
}

func attribute(element xml.StartElement, name string) string {
	for _, attr := range element.Attr {
		if attr.Name.Local == name && attr.Name.Space == "" {
			return attr.Value
		}
	}
	return ""
}

func newDecoder(data []byte) *xml.Decoder {
	decoder := xml.NewDecoder(bytes.NewReader(data))
	decoder.Strict = true
	decoder.Entity = map[string]string{}
	return decoder
}

func tokens(data []byte, visit func(xml.StartElement, []string)) error {
	decoder := newDecoder(data)
	var open []string
	for {
		token, err := decoder.Token()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		switch element := token.(type) {
		case xml.StartElement:
			visit(element, open)
			open = append(open, element.Name.Local)
		case xml.EndElement:
			open = open[:len(open)-1]
		case xml.Directive:
			return ErrUnreadableEPUB
		}
	}
}

func wellFormed(data []byte) error {
	return tokens(data, func(xml.StartElement, []string) {})
}

func firstRootfile(data []byte) (string, error) {
	found, fullPath := false, ""
	err := tokens(data, func(element xml.StartElement, _ []string) {
		if !found && element.Name.Local == "rootfile" {
			found, fullPath = true, attribute(element, "full-path")
		}
	})
	if err != nil || fullPath == "" {
		return "", ErrUnreadableEPUB
	}
	return fullPath, nil
}

func scanPackage(data []byte) (openedPackage, error) {
	opened := openedPackage{items: map[string]manifestItem{}}
	manifests, firstSpine := 0, true
	err := tokens(data, func(element xml.StartElement, open []string) {
		switch element.Name.Local {
		case "package":
			opened.hasPackage = true
		case "metadata":
			opened.hasMetadata = true
		case "manifest":
			opened.hasManifest = true
			manifests++
		case "spine":
			opened.hasSpine = true
			if firstSpine {
				opened.spineTOC = attribute(element, "toc")
				firstSpine = false
			}
		case "item":
			if manifests != 1 || !slices.Contains(open, "manifest") {
				return
			}
			id := attribute(element, "id")
			if _, known := opened.items[id]; !known {
				opened.itemOrder = append(opened.itemOrder, id)
			}
			opened.items[id] = manifestItem{href: attribute(element, "href"), mediaType: attribute(element, "media-type"), properties: strings.Fields(attribute(element, "properties"))}
		case "itemref":
			opened.spine = append(opened.spine, attribute(element, "idref"))
		}
	})
	return opened, err
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
	if joined == "." || joined == ".." || strings.HasPrefix(joined, "../") {
		return "", false
	}
	return joined, true
}

func readEntry(file io.ReaderAt, entry zipdirectory.Entry, limit int64) ([]byte, error) {
	if entry.Name == "" || entry.Size <= 0 || entry.Size > limit || entry.CompressedSize > limit {
		return nil, ErrUnreadableEPUB
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
		return nil, ErrUnreadableEPUB
	}
	data, err := io.ReadAll(io.LimitReader(source, limit+1))
	if err != nil || int64(len(data)) != entry.Size || crc32.ChecksumIEEE(data) != entry.CRC {
		return nil, ErrUnreadableEPUB
	}
	return data, nil
}
