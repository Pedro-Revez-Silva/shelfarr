package webassets

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/safeopen"
)

var ErrInvalid = errors.New("web assets are invalid")

const (
	ManifestName           = "manifest.json"
	PageEngineManifestName = "page-engine.json"
	manifestLimit          = 64 << 10
	fileLimit              = 2 << 20
	totalLimit             = 8 << 20
	maxFiles               = 32
	maxPageEngineFiles     = 256
	pageEngineTotalLimit   = 8 << 20
	digestPrefix           = 16
	immutableCache         = "public, max-age=31536000, immutable"
)

var mediaTypes = map[string]string{
	".js":    "text/javascript; charset=utf-8",
	".css":   "text/css; charset=utf-8",
	".ttf":   "font/ttf",
	".woff2": "font/woff2",
	".png":   "image/png",
}

var pageEngineTypes = map[string]string{
	".js":    "text/javascript; charset=utf-8",
	".bcmap": "application/octet-stream",
	".pfb":   "application/octet-stream",
	".ttf":   "font/ttf",
	".wasm":  "application/wasm",
}

var pageResourceExtensions = map[string][]string{
	"cMapUrl":             {".bcmap"},
	"standardFontDataUrl": {".pfb", ".ttf"},
	"wasmUrl":             {".wasm"},
}

var pageResourceName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9-]{0,63}(\.[a-z]{3,5})$`)

var assetName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9-]{0,63}\.([0-9a-f]{16})(\.[a-z0-9]{2,5})$`)

type manifest struct {
	Version int `json:"version"`
	Entry   struct {
		Script       string `json:"script"`
		Style        string `json:"style"`
		ReaderEngine string `json:"reader_engine,omitempty"`
	} `json:"entry"`
	Files map[string]struct {
		SHA256 string `json:"sha256"`
		Size   int64  `json:"size"`
	} `json:"files"`
}

type listedFile struct {
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
}

type pageEngineManifest struct {
	Version   int                          `json:"version"`
	Script    string                       `json:"script"`
	Engine    string                       `json:"engine"`
	Worker    string                       `json:"worker"`
	Resources map[string]map[string]string `json:"resources"`
	Files     map[string]listedFile        `json:"files"`
}

type PageEngine struct {
	Engine    string
	Worker    string
	Resources map[string]map[string]string
}

type file struct {
	body      []byte
	mediaType string
	etag      string
}

type Bundle struct {
	script       string
	style        string
	readerEngine string
	pageEngine   *PageEngine
	files        map[string]file
	listed       []ListedFile
}

type ListedFile struct {
	Name   string
	SHA256 string
}

func Load(directory string) (*Bundle, error) {
	if !filepath.IsAbs(directory) || filepath.Clean(directory) == "/" {
		return nil, ErrInvalid
	}
	resolved, err := filepath.EvalSymlinks(directory)
	if err != nil {
		return nil, ErrInvalid
	}
	if info, err := os.Stat(resolved); err != nil || !info.IsDir() {
		return nil, ErrInvalid
	}
	raw, err := readRegular(resolved, ManifestName, manifestLimit)
	if err != nil {
		return nil, ErrInvalid
	}
	var listed manifest
	if !decodeStrict(raw, &listed) || listed.Version != 1 || len(listed.Files) == 0 || len(listed.Files) > maxFiles {
		return nil, ErrInvalid
	}
	bundle := &Bundle{script: listed.Entry.Script, style: listed.Entry.Style, readerEngine: listed.Entry.ReaderEngine, files: map[string]file{}}
	listedFiles := make(map[string]listedFile, len(listed.Files))
	for name, expected := range listed.Files {
		listedFiles[name] = listedFile{SHA256: expected.SHA256, Size: expected.Size}
	}
	if err := bundle.add(resolved, listedFiles, mediaTypes, totalLimit); err != nil {
		return nil, err
	}
	for name, expected := range listedFiles {
		bundle.listed = append(bundle.listed, ListedFile{Name: name, SHA256: expected.SHA256})
	}
	slices.SortFunc(bundle.listed, func(left, right ListedFile) int { return strings.Compare(left.Name, right.Name) })
	if !strings.HasSuffix(bundle.script, ".js") || !strings.HasSuffix(bundle.style, ".css") {
		return nil, ErrInvalid
	}
	if _, present := bundle.files[bundle.script]; !present {
		return nil, ErrInvalid
	}
	if _, present := bundle.files[bundle.style]; !present {
		return nil, ErrInvalid
	}
	if bundle.readerEngine != "" {
		if _, present := bundle.files[bundle.readerEngine]; !present || !strings.HasSuffix(bundle.readerEngine, ".js") || bundle.readerEngine == bundle.script {
			return nil, ErrInvalid
		}
	}
	if err := bundle.loadPageEngine(resolved); err != nil {
		return nil, err
	}
	return bundle, nil
}

func (b *Bundle) add(directory string, listed map[string]listedFile, types map[string]string, limit int64) error {
	var total int64
	for name, expected := range listed {
		parts := assetName.FindStringSubmatch(name)
		if parts == nil {
			return ErrInvalid
		}
		media, known := types[parts[2]]
		if _, taken := b.files[name]; taken || !known || len(expected.SHA256) != sha256.Size*2 || expected.Size <= 0 || expected.Size > fileLimit {
			return ErrInvalid
		}
		body, err := readRegular(directory, name, fileLimit)
		if err != nil || int64(len(body)) != expected.Size {
			return ErrInvalid
		}
		digest := sha256.Sum256(body)
		encoded := hex.EncodeToString(digest[:])
		if encoded != expected.SHA256 || encoded[:digestPrefix] != parts[1] {
			return ErrInvalid
		}
		total += int64(len(body))
		if total > limit {
			return ErrInvalid
		}
		b.files[name] = file{body: body, mediaType: media, etag: `"` + encoded + `"`}
	}
	return nil
}

func (b *Bundle) loadPageEngine(directory string) error {
	if _, err := os.Lstat(filepath.Join(directory, PageEngineManifestName)); errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if b.readerEngine == "" {
		return ErrInvalid
	}
	raw, err := readRegular(directory, PageEngineManifestName, manifestLimit)
	if err != nil {
		return ErrInvalid
	}
	var listed pageEngineManifest
	if !decodeStrict(raw, &listed) || listed.Version != 1 || listed.Script != b.script || len(listed.Files) == 0 || len(listed.Files) > maxPageEngineFiles {
		return ErrInvalid
	}
	referenced := map[string]bool{listed.Engine: true, listed.Worker: true}
	if listed.Engine == listed.Worker || !strings.HasSuffix(listed.Engine, ".js") || !strings.HasSuffix(listed.Worker, ".js") || len(listed.Resources) != len(pageResourceExtensions) {
		return ErrInvalid
	}
	for kind, names := range listed.Resources {
		allowed, known := pageResourceExtensions[kind]
		if !known || len(names) == 0 {
			return ErrInvalid
		}
		for logical, stored := range names {
			parts := pageResourceName.FindStringSubmatch(logical)
			if parts == nil || !slices.Contains(allowed, parts[1]) || filepath.Ext(stored) != parts[1] || referenced[stored] {
				return ErrInvalid
			}
			referenced[stored] = true
		}
	}
	if len(referenced) != len(listed.Files) {
		return ErrInvalid
	}
	for name := range referenced {
		if _, present := listed.Files[name]; !present {
			return ErrInvalid
		}
	}
	if err := b.add(directory, listed.Files, pageEngineTypes, pageEngineTotalLimit); err != nil {
		return err
	}
	b.pageEngine = &PageEngine{Engine: listed.Engine, Worker: listed.Worker, Resources: listed.Resources}
	return nil
}

func decodeStrict(raw []byte, into any) bool {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(into); err != nil {
		return false
	}
	var rest json.RawMessage
	return errors.Is(decoder.Decode(&rest), io.EOF)
}

func readRegular(directory, name string, limit int64) ([]byte, error) {
	opened, err := safeopen.Regular(filepath.Join(directory, name))
	if err != nil {
		return nil, ErrInvalid
	}
	defer opened.Close()
	body, err := io.ReadAll(io.LimitReader(opened, limit+1))
	if err != nil || int64(len(body)) > limit {
		return nil, ErrInvalid
	}
	return body, nil
}

func (b *Bundle) Script() string { return b.script }

func (b *Bundle) Style() string { return b.style }

func (b *Bundle) ReaderEngine() string { return b.readerEngine }

func (b *Bundle) PageEngine() *PageEngine { return b.pageEngine }

func (b *Bundle) Listed() []ListedFile { return slices.Clone(b.listed) }

func (b *Bundle) Has(name string) bool {
	_, present := b.files[name]
	return present
}

func (b *Bundle) Serve(w http.ResponseWriter, r *http.Request, name string) bool {
	found, present := b.files[name]
	if !present {
		return false
	}
	header := w.Header()
	header.Set("Content-Type", found.mediaType)
	header.Set("Cache-Control", immutableCache)
	header.Set("X-Content-Type-Options", "nosniff")
	header.Set("Cross-Origin-Resource-Policy", "same-origin")
	header.Set("ETag", found.etag)
	http.ServeContent(w, r, "", time.Time{}, bytes.NewReader(found.body))
	return true
}
