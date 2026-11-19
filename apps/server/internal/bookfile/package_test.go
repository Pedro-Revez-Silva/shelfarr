package bookfile

import (
	"archive/zip"
	"bytes"
	"context"
	"errors"
	"hash/crc32"
	"strings"
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
	opfTemplate = `<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>T</dc:title></metadata><manifest><item id="c1" href="HREF" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c1"/></spine></package>`
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
	gutenbergChapter := `<?xml version="1.0" encoding="utf-8"?><!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd"><html xmlns="http://www.w3.org/1999/xhtml"><body><p>Text</p></body></html>`
	html5Navigation := `<package><metadata/><manifest><item id="c1" href="c.xhtml"/><item id="nav" href="nav.xhtml" properties="nav"/></manifest><spine><itemref idref="c1"/></spine></package>`
	if err := readable(t, map[string]string{"META-INF/container.xml": container, "OEBPS/content.opf": html5Navigation, "OEBPS/c.xhtml": gutenbergChapter, "OEBPS/nav.xhtml": "<!DOCTYPE html><html><nav/></html>"}); err != nil {
		t.Fatalf("an EPUB with document types the reader accepts was refused: %v", err)
	}
	ncx := `<package><metadata/><manifest><item id="c1" href="c.xhtml"/><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest><spine toc="ncx"><itemref idref="c1"/></spine></package>`
	if err := readable(t, map[string]string{"META-INF/container.xml": container, "OEBPS/content.opf": ncx, "OEBPS/c.xhtml": "<html/>", "OEBPS/toc.ncx": `<ncx><navMap><navPoint id="p"><navLabel><text>One</text></navLabel><content src="c.xhtml"/></navPoint></navMap></ncx>`}); err != nil {
		t.Fatalf("an EPUB with a complete NCX was refused: %v", err)
	}
	withNavigation := `<package xmlns="http://www.idpf.org/2007/opf"><metadata/><manifest><item id="c1" href="c.xhtml"/><item id="nav" href="nav.xhtml" properties="nav"/></manifest><spine><itemref idref="c1"/></spine></package>`
	if err := readable(t, map[string]string{"META-INF/container.xml": container, "OEBPS/content.opf": withNavigation, "OEBPS/c.xhtml": "<html/>", "OEBPS/nav.xhtml": "<html><nav/></html>"}); err != nil {
		t.Fatalf("a readable EPUB with navigation was refused: %v", err)
	}
	for name, files := range map[string]map[string]string{
		"an empty container":                       {"META-INF/container.xml": "<container/>"},
		"a missing package":                        {"META-INF/container.xml": container},
		"a spine document missing":                 {"META-INF/container.xml": container, "OEBPS/content.opf": opf("chapter.xhtml")},
		"a spine leaving the archive":              {"META-INF/container.xml": container, "OEBPS/content.opf": opf("../../chapter.xhtml"), "chapter.xhtml": "<html/>"},
		"a spine on another host":                  {"META-INF/container.xml": container, "OEBPS/content.opf": opf("https://example.test/chapter.xhtml")},
		"a package that is not XML":                {"META-INF/container.xml": container, "OEBPS/content.opf": "<package"},
		"a package with an entity":                 {"META-INF/container.xml": container, "OEBPS/content.opf": `<!DOCTYPE p [<!ENTITY x "c">]><package><metadata/><manifest><item id="c1" href="&x;"/></manifest><spine><itemref idref="c1"/></spine></package>`, "OEBPS/c": "<html/>"},
		"a spine naming no manifest item":          {"META-INF/container.xml": container, "OEBPS/content.opf": `<package><metadata/><manifest/><spine><itemref idref="c1"/></spine></package>`},
		"a package without metadata":               {"META-INF/container.xml": container, "OEBPS/content.opf": `<package><manifest><item id="c1" href="c.xhtml"/></manifest><spine><itemref idref="c1"/></spine></package>`, "OEBPS/c.xhtml": "<html/>"},
		"a renamed package element":                {"META-INF/container.xml": container, "OEBPS/content.opf": strings.ReplaceAll(opf("c.xhtml"), "package", "other"), "OEBPS/c.xhtml": "<html/>"},
		"a first spine document missing":           {"META-INF/container.xml": container, "OEBPS/content.opf": `<package><metadata/><manifest><item id="a" href="gone.xhtml"/><item id="b" href="c.xhtml"/></manifest><spine><itemref idref="a"/><itemref idref="b"/></spine></package>`, "OEBPS/c.xhtml": "<html/>"},
		"a navigation document missing":            {"META-INF/container.xml": container, "OEBPS/content.opf": `<package><metadata/><manifest><item id="c1" href="c.xhtml"/><item id="nav" href="nav.xhtml" properties="nav"/></manifest><spine><itemref idref="c1"/></spine></package>`, "OEBPS/c.xhtml": "<html/>"},
		"a navigation document not XML":            {"META-INF/container.xml": container, "OEBPS/content.opf": `<package><metadata/><manifest><item id="c1" href="c.xhtml"/><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest><spine toc="ncx"><itemref idref="c1"/></spine></package>`, "OEBPS/c.xhtml": "<html/>", "OEBPS/toc.ncx": "<ncx"},
		"a first linear document missing":          {"META-INF/container.xml": container, "OEBPS/content.opf": `<package><metadata/><manifest><item id="a" href="c.xhtml"/><item id="b" href="missing.xhtml"/></manifest><spine><itemref idref="a" linear="no"/><itemref idref="b"/></spine></package>`, "OEBPS/c.xhtml": "<html/>"},
		"only documents outside the reading order": {"META-INF/container.xml": container, "OEBPS/content.opf": `<package><metadata/><manifest><item id="a" href="c.xhtml"/></manifest><spine><itemref idref="a" linear="no"/></spine></package>`, "OEBPS/c.xhtml": "<html/>"},
		"a first document that is not XML":         {"META-INF/container.xml": container, "OEBPS/content.opf": opf("c.xhtml"), "OEBPS/c.xhtml": "<html"},
		"an NCX entry without content":             {"META-INF/container.xml": container, "OEBPS/content.opf": `<package><metadata/><manifest><item id="c1" href="c.xhtml"/><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest><spine toc="ncx"><itemref idref="c1"/></spine></package>`, "OEBPS/c.xhtml": "<html/>", "OEBPS/toc.ncx": `<ncx><navMap><navPoint id="p"><navLabel><text>One</text></navLabel></navPoint></navMap></ncx>`},
		"a document type with declarations":        {"META-INF/container.xml": container, "OEBPS/content.opf": opf("c.xhtml"), "OEBPS/c.xhtml": `<!DOCTYPE html [<!ENTITY x "y">]><html/>`},
		"a first rootfile that is missing":         {"META-INF/container.xml": `<container><rootfiles><rootfile full-path="missing.opf" media-type="text/plain"/><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>`, "OEBPS/content.opf": opf("c.xhtml"), "OEBPS/c.xhtml": "<html/>"},
	} {
		if err := readable(t, files); !errors.Is(err, ErrUnreadableEPUB) {
			t.Errorf("%s: %v", name, err)
		}
	}
}
