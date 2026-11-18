package webassets

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/webassets/webassetstest"
)

func built(t *testing.T) (string, webassetstest.Manifest) {
	t.Helper()
	directory := t.TempDir()
	return directory, webassetstest.Write(t, directory)
}

func TestLoadServesOnlyTheListedFilesWithTheirDigestsAndSafeHeaders(t *testing.T) {
	directory, listed := built(t)
	if err := os.WriteFile(filepath.Join(directory, "preview.js.map"), []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	bundle, err := Load(directory)
	if err != nil {
		t.Fatal(err)
	}
	if bundle.Script() != listed.Entry.Script || bundle.Style() != listed.Entry.Style {
		t.Fatal("entry points differ from the manifest")
	}
	types := map[string]string{listed.Entry.Script: "text/javascript; charset=utf-8", listed.Entry.Style: "text/css; charset=utf-8"}
	for name, mediaType := range types {
		recorder := httptest.NewRecorder()
		if !bundle.Serve(recorder, httptest.NewRequest(http.MethodGet, "/", nil), name) {
			t.Fatalf("%s is not served", name)
		}
		header := recorder.Header()
		if recorder.Code != http.StatusOK || header.Get("Content-Type") != mediaType || header.Get("X-Content-Type-Options") != "nosniff" || header.Get("Cache-Control") != "public, max-age=31536000, immutable" || header.Get("ETag") != `"`+listed.Files[name].SHA256+`"` {
			t.Errorf("%s: %d %v", name, recorder.Code, header)
		}
	}
	for _, name := range []string{"preview.js.map", "manifest.json", "../manifest.json", ""} {
		if bundle.Has(name) || bundle.Serve(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/", nil), name) {
			t.Errorf("%q must not be served", name)
		}
	}
}

func TestServeAnswersConditionalRangeAndHeadRequestsWithoutABody(t *testing.T) {
	directory, listed := built(t)
	bundle, err := Load(directory)
	if err != nil {
		t.Fatal(err)
	}
	name := listed.Entry.Script
	conditional := httptest.NewRequest(http.MethodGet, "/", nil)
	conditional.Header.Set("If-None-Match", `"`+listed.Files[name].SHA256+`"`)
	recorder := httptest.NewRecorder()
	bundle.Serve(recorder, conditional, name)
	if recorder.Code != http.StatusNotModified || recorder.Body.Len() != 0 {
		t.Errorf("conditional: %d %q", recorder.Code, recorder.Body.String())
	}
	recorder = httptest.NewRecorder()
	bundle.Serve(recorder, httptest.NewRequest(http.MethodHead, "/", nil), name)
	if recorder.Code != http.StatusOK || recorder.Body.Len() != 0 || recorder.Header().Get("Content-Length") == "" {
		t.Errorf("head: %d %d", recorder.Code, recorder.Body.Len())
	}
}

func TestLoadRefusesUnsafeOrInconsistentDirectories(t *testing.T) {
	type mutation struct {
		name  string
		apply func(t *testing.T, directory string, listed webassetstest.Manifest)
	}
	rewrite := func(change func(*webassetstest.Manifest)) func(*testing.T, string, webassetstest.Manifest) {
		return func(t *testing.T, directory string, listed webassetstest.Manifest) {
			change(&listed)
			webassetstest.WriteManifest(t, directory, listed)
		}
	}
	swap := func(name string, replace func(directory, path string)) func(*testing.T, string, webassetstest.Manifest) {
		return func(t *testing.T, directory string, listed webassetstest.Manifest) {
			path := filepath.Join(directory, listed.Entry.Script)
			if name == "style" {
				path = filepath.Join(directory, listed.Entry.Style)
			}
			if err := os.Remove(path); err != nil {
				t.Fatal(err)
			}
			replace(directory, path)
		}
	}
	mutations := []mutation{
		{"missing manifest", func(t *testing.T, directory string, _ webassetstest.Manifest) {
			os.Remove(filepath.Join(directory, "manifest.json"))
		}},
		{"manifest is a symlink", func(t *testing.T, directory string, _ webassetstest.Manifest) {
			os.Rename(filepath.Join(directory, "manifest.json"), filepath.Join(directory, "real.json"))
			os.Symlink(filepath.Join(directory, "real.json"), filepath.Join(directory, "manifest.json"))
		}},
		{"manifest is not json", func(t *testing.T, directory string, _ webassetstest.Manifest) {
			os.WriteFile(filepath.Join(directory, "manifest.json"), []byte("{"), 0o600)
		}},
		{"manifest has an unknown field", func(t *testing.T, directory string, _ webassetstest.Manifest) {
			os.WriteFile(filepath.Join(directory, "manifest.json"), []byte(`{"version":1,"extra":true}`), 0o600)
		}},
		{"manifest is oversized", func(t *testing.T, directory string, _ webassetstest.Manifest) {
			encoded, _ := os.ReadFile(filepath.Join(directory, "manifest.json"))
			os.WriteFile(filepath.Join(directory, "manifest.json"), append(encoded, bytes.Repeat([]byte(" "), manifestLimit)...), 0o600)
		}},
		{"another version", rewrite(func(m *webassetstest.Manifest) { m.Version = 2 })},
		{"script is a symlink", swap("script", func(directory, path string) {
			os.WriteFile(filepath.Join(directory, "elsewhere"), []byte("console.log('shelfarr');\n"), 0o600)
			os.Symlink(filepath.Join(directory, "elsewhere"), path)
		})},
		{"style is a fifo", swap("style", func(_, path string) { syscall.Mkfifo(path, 0o600) })},
		{"script is a directory", swap("script", func(_, path string) { os.Mkdir(path, 0o700) })},
		{"script is missing", swap("script", func(_, _ string) {})},
		{"script content changed", func(t *testing.T, directory string, listed webassetstest.Manifest) {
			os.WriteFile(filepath.Join(directory, listed.Entry.Script), []byte("console.log('tampered');\n"), 0o600)
		}},
		{"script grew past its listed size", func(t *testing.T, directory string, listed webassetstest.Manifest) {
			entry := listed.Files[listed.Entry.Script]
			entry.Size++
			listed.Files[listed.Entry.Script] = entry
			webassetstest.WriteManifest(t, directory, listed)
		}},
		{"oversized file", func(t *testing.T, directory string, listed webassetstest.Manifest) {
			big := bytes.Repeat([]byte("a"), fileLimit+1)
			name := webassetstest.Name("big", big, ".js")
			os.WriteFile(filepath.Join(directory, name), big, 0o600)
			listed.Files[name] = webassetstest.Describe(big)
			webassetstest.WriteManifest(t, directory, listed)
		}},
		{"name does not carry the digest", func(t *testing.T, directory string, listed webassetstest.Manifest) {
			body := []byte("x")
			os.WriteFile(filepath.Join(directory, "preview.0000000000000000.js"), body, 0o600)
			listed.Files["preview.0000000000000000.js"] = webassetstest.Describe(body)
			webassetstest.WriteManifest(t, directory, listed)
		}},
		{"source map listed", func(t *testing.T, directory string, listed webassetstest.Manifest) {
			body := []byte("{}")
			name := webassetstest.Name("preview", body, ".map")
			os.WriteFile(filepath.Join(directory, name), body, 0o600)
			listed.Files[name] = webassetstest.Describe(body)
			webassetstest.WriteManifest(t, directory, listed)
		}},
		{"traversal name", rewrite(func(m *webassetstest.Manifest) {
			m.Files["../preview.0000000000000000.js"] = webassetstest.Describe([]byte("x"))
		})},
		{"hidden name", rewrite(func(m *webassetstest.Manifest) {
			m.Files[".preview.0000000000000000.js"] = webassetstest.Describe([]byte("x"))
		})},
		{"entry not listed", rewrite(func(m *webassetstest.Manifest) { m.Entry.Script = "other.0000000000000000.js" })},
		{"entry has the wrong type", rewrite(func(m *webassetstest.Manifest) { m.Entry.Script, m.Entry.Style = m.Entry.Style, m.Entry.Script })},
		{"files together exceed the total", func(t *testing.T, directory string, listed webassetstest.Manifest) {
			for index := 0; index < totalLimit/fileLimit+1; index++ {
				body := bytes.Repeat([]byte{byte('a' + index)}, fileLimit)
				name := webassetstest.Name("big", body, ".js")
				os.WriteFile(filepath.Join(directory, name), body, 0o600)
				listed.Files[name] = webassetstest.Describe(body)
			}
			webassetstest.WriteManifest(t, directory, listed)
		}},
		{"no files", rewrite(func(m *webassetstest.Manifest) { m.Files = map[string]webassetstest.Entry{} })},
		{"too many files", rewrite(func(m *webassetstest.Manifest) {
			for index := 0; index <= maxFiles; index++ {
				m.Files[strings.Repeat("a", index+1)+".0000000000000000.js"] = webassetstest.Entry{}
			}
		})},
	}
	for _, test := range mutations {
		t.Run(test.name, func(t *testing.T) {
			directory, listed := built(t)
			test.apply(t, directory, listed)
			if bundle, err := Load(directory); err == nil || bundle != nil {
				t.Fatalf("accepted a directory with: %s", test.name)
			}
		})
	}
}

func TestLoadRefusesDirectoriesThatAreNotAbsoluteExistingFolders(t *testing.T) {
	directory, _ := built(t)
	file := filepath.Join(t.TempDir(), "file")
	os.WriteFile(file, nil, 0o600)
	for _, candidate := range []string{"", ".", "relative/path", "/", filepath.Join(directory, "missing"), file} {
		if _, err := Load(candidate); err == nil {
			t.Errorf("%q was accepted", candidate)
		}
	}
	linked := filepath.Join(t.TempDir(), "link")
	if err := os.Symlink(directory, linked); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(linked); err != nil {
		t.Errorf("the operator may name the assets through a symlinked folder: %v", err)
	}
}

func TestLoadNeverTouchesTheWorkingDirectory(t *testing.T) {
	_, listed := built(t)
	elsewhere := t.TempDir()
	webassetstest.WriteManifest(t, elsewhere, listed)
	t.Chdir(elsewhere)
	for _, candidate := range []string{"", ".", "manifest.json"} {
		if _, err := Load(candidate); err == nil {
			t.Errorf("%q was accepted", candidate)
		}
	}
}

func TestTheReaderEngineIsOptionalAndMustBeAListedScriptOtherThanTheEntry(t *testing.T) {
	plain, _ := built(t)
	bundle, err := Load(plain)
	if err != nil || bundle.ReaderEngine() != "" {
		t.Fatalf("a manifest without a reader engine must load without one: %v %q", err, bundle.ReaderEngine())
	}
	directory := t.TempDir()
	listed := webassetstest.WriteWithReaderEngine(t, directory)
	bundle, err = Load(directory)
	if err != nil || bundle.ReaderEngine() != listed.Entry.ReaderEngine || !bundle.Has(listed.Entry.ReaderEngine) {
		t.Fatalf("the listed reader engine must load: %v", err)
	}
	for name, engine := range map[string]string{"unlisted": "reader-engine.0123456789abcdef.js", "the entry script": listed.Entry.Script, "a stylesheet": listed.Entry.Style} {
		changed := listed
		changed.Entry.ReaderEngine = engine
		webassetstest.WriteManifest(t, directory, changed)
		if _, err := Load(directory); err == nil {
			t.Errorf("%s as the reader engine must be refused", name)
		}
	}
}
