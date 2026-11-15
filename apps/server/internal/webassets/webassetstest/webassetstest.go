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
		Script string `json:"script"`
		Style  string `json:"style"`
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
