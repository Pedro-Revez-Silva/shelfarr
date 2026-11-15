package webassets

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/safeopen"
)

var ErrInvalid = errors.New("web assets are invalid")

const (
	ManifestName   = "manifest.json"
	manifestLimit  = 64 << 10
	fileLimit      = 2 << 20
	totalLimit     = 8 << 20
	maxFiles       = 32
	digestPrefix   = 16
	immutableCache = "public, max-age=31536000, immutable"
)

var mediaTypes = map[string]string{
	".js":    "text/javascript; charset=utf-8",
	".css":   "text/css; charset=utf-8",
	".ttf":   "font/ttf",
	".woff2": "font/woff2",
	".png":   "image/png",
}

var assetName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9-]{0,63}\.([0-9a-f]{16})(\.[a-z0-9]{2,5})$`)

type manifest struct {
	Version int `json:"version"`
	Entry   struct {
		Script string `json:"script"`
		Style  string `json:"style"`
	} `json:"entry"`
	Files map[string]struct {
		SHA256 string `json:"sha256"`
		Size   int64  `json:"size"`
	} `json:"files"`
}

type file struct {
	body      []byte
	mediaType string
	etag      string
}

type Bundle struct {
	script string
	style  string
	files  map[string]file
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
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&listed); err != nil || decoder.More() || listed.Version != 1 || len(listed.Files) == 0 || len(listed.Files) > maxFiles {
		return nil, ErrInvalid
	}
	bundle := &Bundle{script: listed.Entry.Script, style: listed.Entry.Style, files: map[string]file{}}
	var total int64
	for name, expected := range listed.Files {
		parts := assetName.FindStringSubmatch(name)
		if parts == nil {
			return nil, ErrInvalid
		}
		media, known := mediaTypes[parts[2]]
		if !known || len(expected.SHA256) != sha256.Size*2 || expected.Size <= 0 || expected.Size > fileLimit {
			return nil, ErrInvalid
		}
		body, err := readRegular(resolved, name, fileLimit)
		if err != nil || int64(len(body)) != expected.Size {
			return nil, ErrInvalid
		}
		digest := sha256.Sum256(body)
		encoded := hex.EncodeToString(digest[:])
		if encoded != expected.SHA256 || encoded[:digestPrefix] != parts[1] {
			return nil, ErrInvalid
		}
		total += int64(len(body))
		if total > totalLimit {
			return nil, ErrInvalid
		}
		bundle.files[name] = file{body: body, mediaType: media, etag: `"` + encoded + `"`}
	}
	if !strings.HasSuffix(bundle.script, ".js") || !strings.HasSuffix(bundle.style, ".css") {
		return nil, ErrInvalid
	}
	if _, present := bundle.files[bundle.script]; !present {
		return nil, ErrInvalid
	}
	if _, present := bundle.files[bundle.style]; !present {
		return nil, ErrInvalid
	}
	return bundle, nil
}

func readRegular(directory, name string, limit int64) ([]byte, error) {
	opened, err := safeopen.Regular(filepath.Join(directory, name))
	if err != nil {
		return nil, ErrInvalid
	}
	defer opened.Close()
	body, err := io.ReadAll(io.LimitReader(opened, limit+1))
	if err != nil {
		return nil, ErrInvalid
	}
	return body, nil
}

func (b *Bundle) Script() string { return b.script }

func (b *Bundle) Style() string { return b.style }

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
