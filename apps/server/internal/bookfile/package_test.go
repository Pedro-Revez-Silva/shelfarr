package bookfile

import (
	"archive/zip"
	"bytes"
	"context"
	"errors"
	"hash/crc32"
	"testing"
)

func archiveOf(t *testing.T, files map[string]string, order ...string) *bytes.Reader {
	t.Helper()
	var buffer bytes.Buffer
	archive := zip.NewWriter(&buffer)
	mimetype := []byte(epubMediaType)
	writer, err := archive.CreateRaw(&zip.FileHeader{Name: "mimetype", Method: zip.Store, CRC32: crc32.ChecksumIEEE(mimetype), CompressedSize64: uint64(len(mimetype)), UncompressedSize64: uint64(len(mimetype))})
	if err != nil {
		t.Fatal(err)
	}
	writer.Write(mimetype)
	for _, name := range order {
		entry, err := archive.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		entry.Write([]byte(files[name]))
	}
	if err := archive.Close(); err != nil {
		t.Fatal(err)
	}
	return bytes.NewReader(buffer.Bytes())
}

const (
	container   = `<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>`
	opfTemplate = `<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0"><manifest><item id="c1" href="HREF" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c1"/></spine></package>`
)

func readable(t *testing.T, files map[string]string) error {
	t.Helper()
	order := []string{"META-INF/container.xml"}
	for name := range files {
		if name != "META-INF/container.xml" {
			order = append(order, name)
		}
	}
	file := archiveOf(t, files, order...)
	return CheckReadableEPUB(context.Background(), file, file.Size())
}

func TestAReadableEPUBHasAPackageAndASpineDocument(t *testing.T) {
	opf := func(href string) string {
		return string(bytes.ReplaceAll([]byte(opfTemplate), []byte("HREF"), []byte(href)))
	}
	if err := readable(t, map[string]string{"META-INF/container.xml": container, "OEBPS/content.opf": opf("text/chapter.xhtml"), "OEBPS/text/chapter.xhtml": "<html/>"}); err != nil {
		t.Fatalf("a readable EPUB was refused: %v", err)
	}
	for name, files := range map[string]map[string]string{
		"an empty container":              {"META-INF/container.xml": "<container/>"},
		"a missing package":               {"META-INF/container.xml": container},
		"a spine document missing":        {"META-INF/container.xml": container, "OEBPS/content.opf": opf("chapter.xhtml")},
		"a spine leaving the archive":     {"META-INF/container.xml": container, "OEBPS/content.opf": opf("../../chapter.xhtml"), "chapter.xhtml": "<html/>"},
		"a spine on another host":         {"META-INF/container.xml": container, "OEBPS/content.opf": opf("https://example.test/chapter.xhtml")},
		"a package that is not XML":       {"META-INF/container.xml": container, "OEBPS/content.opf": "<package"},
		"a package with an entity":        {"META-INF/container.xml": container, "OEBPS/content.opf": `<!DOCTYPE p [<!ENTITY x "c">]><package><manifest><item id="c1" href="&x;"/></manifest><spine><itemref idref="c1"/></spine></package>`, "OEBPS/c": "<html/>"},
		"a spine naming no manifest item": {"META-INF/container.xml": container, "OEBPS/content.opf": `<package><manifest/><spine><itemref idref="c1"/></spine></package>`},
	} {
		if err := readable(t, files); !errors.Is(err, ErrUnreadableEPUB) {
			t.Errorf("%s: %v", name, err)
		}
	}
}
