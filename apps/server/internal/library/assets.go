package library

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"unicode/utf8"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/assetid"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
)

const (
	maxEntries   = 2000
	maxDepth     = 8
	maxEpubBytes = 250 << 20
)

var audioTypes = map[string]string{
	"mp3": "audio/mpeg", "m4b": "audio/mp4", "m4a": "audio/mp4", "aac": "audio/aac",
	"ogg": "audio/ogg", "opus": "audio/ogg", "flac": "audio/flac", "wav": "audio/wav",
}

type Asset struct {
	ID        string
	Path      string
	Root      string
	Filename  string
	Format    string
	MediaType string
	SizeBytes int64
	Position  int
	Stat      assetid.Stat
}

type Listing struct {
	Unavailable bool
	Assets      []Asset
}

type errSkip struct{ cause error }

func (e errSkip) Error() string { return "asset skipped" }

var fixedLayoutLimits = map[string]int64{"pdf": 500 << 20, "cbz": 2 << 30}

var errUnavailable = errors.New("publication media is unavailable")

type boundary struct {
	target string
	root   string
	dir    bool
}

type Lister struct {
	Roots   []string
	Formats []string
}

func rubyExt(path string) string {
	base := filepath.Base(path)
	trimmed := strings.TrimLeft(base, ".")
	index := strings.LastIndex(trimmed, ".")
	if index < 0 {
		return ""
	}
	return trimmed[index:]
}

func extension(path string) string {
	return strings.ToLower(strings.TrimPrefix(rubyExt(path), "."))
}

var readingTypes = map[string]string{
	"epub": "application/epub+zip", "kepub": "application/epub+zip",
	"pdf": "application/pdf", "cbz": "application/vnd.comicbook+zip",
}

var defaultFormats = []string{"epub"}

func (l Lister) formats() []string {
	if l.Formats == nil {
		return defaultFormats
	}
	return l.Formats
}

func (l Lister) mediaType(book store.Book, path string) (string, bool) {
	ext := extension(path)
	if book.BookType == store.BookTypeAudiobook {
		value, ok := audioTypes[ext]
		return value, ok
	}
	name := ext
	if name == "kepub" {
		name = "epub"
	}
	for _, format := range l.formats() {
		if format == name {
			value, ok := readingTypes[ext]
			return value, ok
		}
	}
	return "", false
}

func assetFormat(book store.Book, path string) string {
	ext := extension(path)
	if book.BookType == store.BookTypeAudiobook {
		return ext
	}
	if ext == "kepub" {
		return "epub"
	}
	return ext
}

func (l Lister) canonicalBoundary(path string) (boundary, error) {
	if strings.TrimSpace(path) == "" {
		return boundary{}, errSkip{}
	}
	expanded, err := expand(path)
	if err != nil {
		return boundary{}, err
	}
	linkInfo, err := os.Lstat(expanded)
	if err != nil {
		return boundary{}, errSkip{err}
	}
	if linkInfo.Mode()&os.ModeSymlink != 0 {
		return boundary{}, ErrReference
	}
	target, err := filepath.EvalSymlinks(expanded)
	if err != nil {
		return boundary{}, errSkip{err}
	}
	info, err := os.Lstat(target)
	if err != nil {
		return boundary{}, errSkip{err}
	}
	if !info.Mode().IsRegular() && !info.IsDir() {
		return boundary{}, errSkip{}
	}
	root, ok := containingRoot(target, l.Roots)
	if !ok {
		return boundary{}, errSkip{}
	}
	return boundary{target: target, root: root, dir: info.IsDir()}, nil
}

func (l Lister) List(book store.Book, bookPath string) (Listing, error) {
	assets, err := l.listAssets(book, bookPath)
	var skip errSkip
	switch {
	case errors.Is(err, errUnavailable), errors.As(err, &skip):
		return Listing{Unavailable: true}, nil
	case err != nil:
		return Listing{}, err
	}
	return Listing{Assets: assets}, nil
}

func (l Lister) listAssets(book store.Book, bookPath string) ([]Asset, error) {
	candidates, err := l.candidates(book, bookPath)
	if err != nil {
		return nil, err
	}
	var assets []Asset
	for _, candidate := range candidates {
		asset, err := l.asset(book, bookPath, candidate)
		var skip errSkip
		if errors.As(err, &skip) {
			continue
		}
		if err != nil {
			return nil, err
		}
		asset.Position = len(assets)
		assets = append(assets, asset)
	}
	return assets, nil
}

func (l Lister) candidates(book store.Book, bookPath string) ([]string, error) {
	located, err := l.canonicalBoundary(bookPath)
	if err != nil {
		return nil, err
	}
	paths := []string{bookPath}
	if located.dir {
		if located.target == located.root {
			return nil, errUnavailable
		}
		if paths, err = l.directoryFiles(book, located); err != nil {
			return nil, err
		}
	}
	var selected []string
	for _, path := range paths {
		if !utf8.ValidString(path) {
			return nil, errUnavailable
		}
		if _, ok := l.mediaType(book, path); ok {
			selected = append(selected, path)
		}
	}
	sortNatural(selected)
	return selected, nil
}

type pendingDirectory struct {
	path  string
	depth int
}

func (l Lister) directoryFiles(book store.Book, start boundary) ([]string, error) {
	var files []string
	pending := []pendingDirectory{{start.target, 0}}
	count := 0
	for len(pending) > 0 {
		current := pending[len(pending)-1]
		pending = pending[:len(pending)-1]
		if current.depth > maxDepth {
			return nil, errUnavailable
		}
		located, err := l.canonicalBoundary(current.path)
		if err != nil {
			return nil, err
		}
		if !located.dir {
			return nil, errUnavailable
		}
		entries, err := os.ReadDir(located.target)
		if err != nil {
			return nil, errSkip{err}
		}
		for _, entry := range entries {
			count++
			if count > maxEntries {
				return nil, errUnavailable
			}
			if strings.HasPrefix(entry.Name(), ".") {
				continue
			}
			path := filepath.Join(located.target, entry.Name())
			info, err := os.Lstat(path)
			if err != nil {
				return nil, errSkip{err}
			}
			if info.IsDir() {
				pending = append(pending, pendingDirectory{path, current.depth + 1})
			} else if _, ok := l.mediaType(book, path); ok {
				files = append(files, path)
			}
		}
	}
	return files, nil
}

func (l Lister) asset(book store.Book, bookPath, path string) (Asset, error) {
	located, err := l.canonicalBoundary(path)
	if err != nil {
		return Asset{}, err
	}
	if located.dir {
		return Asset{}, errUnavailable
	}
	info, err := os.Lstat(located.target)
	if err != nil {
		return Asset{}, errSkip{err}
	}
	stat, err := assetid.StatOf(info)
	if err != nil {
		return Asset{}, err
	}
	format := assetFormat(book, path)
	if format == "epub" && stat.Size > maxEpubBytes {
		return Asset{}, errUnavailable
	}
	if limit, limited := fixedLayoutLimits[format]; limited && stat.Size > limit {
		return Asset{}, errSkip{}
	}
	media, _ := l.mediaType(book, path)
	filename := filepath.Base(path)
	if !utf8.ValidString(filename) {
		return Asset{}, errSkip{}
	}
	return Asset{
		ID:        assetid.ID(assetid.Input{BookID: book.ID, StoredPath: bookPath, CanonicalPath: located.target, Stat: stat}),
		Path:      located.target,
		Root:      located.root,
		Filename:  filename,
		Format:    assetFormat(book, path),
		MediaType: media,
		SizeBytes: stat.Size,
		Stat:      stat,
	}, nil
}
