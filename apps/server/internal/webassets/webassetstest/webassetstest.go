package webassetstest

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

type Entry struct {
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
}

type Manifest struct {
	Version int `json:"version"`
	Entry   struct {
		Script       string `json:"script"`
		Style        string `json:"style"`
		ReaderEngine string `json:"reader_engine,omitempty"`
	} `json:"entry"`
	Files map[string]Entry `json:"files"`
}

func Name(stem string, body []byte, extension string) string {
	digest := sha256.Sum256(body)
	return stem + "." + hex.EncodeToString(digest[:])[:16] + extension
}

func Describe(body []byte) Entry {
	digest := sha256.Sum256(body)
	return Entry{SHA256: hex.EncodeToString(digest[:]), Size: int64(len(body))}
}

func Write(t testing.TB, directory string) Manifest {
	t.Helper()
	script := []byte("console.log('shelfarr');\n")
	style := []byte("body{margin:0}\n")
	font := []byte("not-really-a-font")
	listed := Manifest{Version: 1, Files: map[string]Entry{}}
	listed.Entry.Script = Name("preview", script, ".js")
	listed.Entry.Style = Name("preview", style, ".css")
	for name, body := range map[string][]byte{listed.Entry.Script: script, listed.Entry.Style: style, Name("Newsreader-Regular", font, ".ttf"): font} {
		if err := os.WriteFile(filepath.Join(directory, name), body, 0o600); err != nil {
			t.Fatal(err)
		}
		listed.Files[name] = Describe(body)
	}
	WriteManifest(t, directory, listed)
	return listed
}

func WriteWithReaderEngine(t testing.TB, directory string) Manifest {
	t.Helper()
	listed := Write(t, directory)
	engine := []byte("export const ePub = null;\n")
	listed.Entry.ReaderEngine = Name("reader-engine", engine, ".js")
	if err := os.WriteFile(filepath.Join(directory, listed.Entry.ReaderEngine), engine, 0o600); err != nil {
		t.Fatal(err)
	}
	listed.Files[listed.Entry.ReaderEngine] = Describe(engine)
	WriteManifest(t, directory, listed)
	return listed
}

func WriteManifest(t testing.TB, directory string, listed Manifest) {
	t.Helper()
	encoded, err := json.Marshal(listed)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "manifest.json"), encoded, 0o600); err != nil {
		t.Fatal(err)
	}
}

type PageEngine struct {
	Version   int                          `json:"version"`
	Engine    string                       `json:"engine"`
	Worker    string                       `json:"worker"`
	Resources map[string]map[string]string `json:"resources"`
	Files     map[string]Entry             `json:"files"`
}

func WriteWithPageEngine(t testing.TB, directory string) (Manifest, PageEngine) {
	t.Helper()
	listed := WriteWithReaderEngine(t, directory)
	engine := PageEngine{Version: 1, Resources: map[string]map[string]string{}, Files: map[string]Entry{}}
	add := func(stem string, body []byte, extension string) string {
		name := Name(stem, body, extension)
		if err := os.WriteFile(filepath.Join(directory, name), body, 0o600); err != nil {
			t.Fatal(err)
		}
		engine.Files[name] = Describe(body)
		return name
	}
	engine.Engine = add("pdf-engine", []byte("export const getDocument = null;\n"), ".js")
	engine.Worker = add("pdf-worker", []byte("self.onmessage = null;\n"), ".js")
	engine.Resources["cMapUrl"] = map[string]string{"UniJIS-UTF16-H.bcmap": add("cmap-UniJIS-UTF16-H", []byte("bcmap"), ".bcmap")}
	engine.Resources["standardFontDataUrl"] = map[string]string{
		"FoxitSerif.pfb":             add("font-FoxitSerif", []byte("pfb"), ".pfb"),
		"LiberationSans-Regular.ttf": add("font-LiberationSans-Regular", []byte("ttf"), ".ttf"),
	}
	engine.Resources["wasmUrl"] = map[string]string{"openjpeg.wasm": add("wasm-openjpeg", []byte("\x00asm"), ".wasm")}
	WritePageEngine(t, directory, engine)
	return listed, engine
}

func WritePageEngine(t testing.TB, directory string, engine PageEngine) {
	t.Helper()
	encoded, err := json.Marshal(engine)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "page-engine.json"), encoded, 0o600); err != nil {
		t.Fatal(err)
	}
}
