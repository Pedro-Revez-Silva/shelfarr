//go:build e2e

package httpruntime

import (
	"bytes"
	"context"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type edit struct {
	old string
	new string
}

type mutant struct {
	name     string
	file     string
	edit     edit
	scenario string
	unit     string
}

var differential = "TestDifferentialAgainstRails"

var mutants = []mutant{
	{name: "auth: a revoked credential still authenticates", file: "internal/live/queries.go", edit: edit{"AND revoked_at IS NULL AND (expires_at", "AND (1 OR revoked_at IS NULL) AND (expires_at"}, unit: "./internal/live/", scenario: differential},
	{name: "auth: an expired credential still authenticates", file: "internal/live/queries.go", edit: edit{"(expires_at IS NULL OR expires_at > ?)", "(1 OR expires_at > ?)"}, unit: "./internal/live/", scenario: differential},
	{name: "auth: a deleted account still authenticates", file: "internal/bearer/bearer.go", edit: edit{"if user != nil && user.Deleted {", "if false {"}, unit: "./internal/bearer/", scenario: differential},
	{name: "auth: contention during adoption is reported as an anonymous request", file: "internal/bearer/bearer.go", edit: edit{"if err != nil || !adopted {\n\t\treturn nil, err\n\t}", "if err != nil || !adopted {\n\t\treturn nil, nil\n\t}"}, unit: "./internal/bearer/"},
	{name: "auth: contention while recording use is reported as an anonymous request", file: "internal/bearer/bearer.go", edit: edit{"if err := a.DB.TouchToken(ctx, token.ID, now); err != nil {\n\t\treturn nil, err\n\t}", "if err := a.DB.TouchToken(ctx, token.ID, now); err != nil {\n\t\treturn nil, nil\n\t}"}, unit: "./internal/bearer/", scenario: "TestABusyDatabase"},
	{name: "adoption: the previous credential is not retired", file: "internal/live/tokens.go", edit: edit{"SET revoked_at = ?, updated_at = ? WHERE id = ? AND revoked_at IS NULL`", "SET updated_at = ?, revoked_at = NULL WHERE ? IS NOT NULL AND id = ?`"}, unit: "./internal/live/", scenario: differential},
	{name: "adoption: another account's credential may be adopted", file: "internal/live/tokens.go", edit: edit{"previous.user != token.UserID", "false"}, unit: "./internal/live/", scenario: differential},
	{name: "scopes: library:read is not required", file: "internal/gohttp/app.go", edit: edit{`if !principal.HasScope("library:read") {`, "if false {"}, scenario: differential},
	{name: "cursor: the account is not part of the binding", file: "internal/catalogue/catalogue.go", edit: edit{"parts := []string{strconv.FormatInt(userID, 10), query,", `parts := []string{"0", query,`}, unit: "./internal/catalogue/", scenario: differential},
	{name: "cursor: the signature is not verified", file: "internal/railsmsg/railsmsg.go", edit: edit{"if !hmac.Equal([]byte(digest), []byte(v.sign(text))) {", "if false && !hmac.Equal([]byte(digest), []byte(v.sign(text))) {"}, unit: "./internal/railsmsg/"},
	{name: "path: opens follow symbolic links", file: "internal/media/open_linux.go", edit: edit{"unix.RESOLVE_BENEATH | unix.RESOLVE_NO_SYMLINKS | unix.RESOLVE_NO_MAGICLINKS,", "unix.RESOLVE_BENEATH,"}, unit: "./internal/media/"},
	{name: "path: dotted segments reach the asset routes", file: "internal/gohttp/routes.go", edit: edit{`!strings.ContainsAny(segment, ".?")`, `!strings.ContainsAny(segment, "?")`}, unit: "./internal/gohttp/", scenario: differential},
	{name: "identity: the opened file is not re-checked against the asset id", file: "internal/gohttp/handlers.go", edit: edit{"if current != asset.ID {", "if false && current != asset.ID {"}, unit: "./internal/gohttp/"},
	{name: "roots: a database root outside the configured roots is accepted", file: "internal/gohttp/handlers.go", edit: edit{"if !withinAny(root, a.explicitRoots) {", "if false && !withinAny(root, a.explicitRoots) {"}, scenario: "TestADatabaseRoot"},
	{name: "layout: reference imports are reported as a generic error", file: "internal/gohttp/respond.go", edit: edit{"errors.Is(err, library.ErrReference), errors.Is(err, library.ErrUnsupportedPath)", "errors.Is(err, library.ErrUnsupportedPath)"}, scenario: "TestMissingDeletedReplaced"},
	{name: "formats: fixed-layout assets are served instead of refused", file: "internal/gohttp/handlers.go", edit: edit{`if chosen.Format == "pdf" || chosen.Format == "cbz" {`, "if false {"}, scenario: differential},
	{name: "formats: comic records are served instead of refused", file: "internal/gohttp/handlers.go", edit: edit{"if book.BookType == store.BookTypeComicbook {", "if false {"}, scenario: differential},
	{name: "range: a suffix range reads from the start", file: "internal/media/ranges.go", edit: edit{"return Span{First: max(size-suffix, 0), Last: size - 1}, true", "return Span{First: 0, Last: min(suffix, size) - 1}, true"}, unit: "./internal/media/", scenario: differential},
	{name: "range: HEAD honours a range", file: "internal/media/serve.go", edit: edit{"if r.Method != http.MethodHead && strings.TrimSpace(rangeHeader) != \"\" {", "if strings.TrimSpace(rangeHeader) != \"\" {"}, scenario: differential},
	{name: "conditional: If-None-Match is ignored", file: "internal/media/serve.go", edit: edit{"if etagMatches(strings.Join(", "if false && etagMatches(strings.Join("}, scenario: differential},
	{name: "capacity: media streams are not bounded", file: "internal/gohttp/app.go", edit: edit{"streams:       make(chan struct{}, config.MaxMediaStreams),", "streams:       make(chan struct{}, config.MaxMediaStreams*1000),"}, scenario: "TestStalledMediaClients|TestAClientThatDisconnects"},
	{name: "startup: an unknown schema revision is accepted", file: "internal/live/live.go", edit: edit{"if !contains(SupportedRevisions, revision) {", "if false && !contains(SupportedRevisions, revision) {"}, unit: "./internal/live/", scenario: "TestStartupRefuses"},
	{name: "startup: a missing secret key base is replaced by a default", file: "internal/gohttp/secret.go", edit: edit{"return \"\", ErrSecretMissing", "return \"development-secret-key-base-development-secret-key-base\", nil"}, unit: "./internal/gohttp/", scenario: "TestStartupRefuses"},
	{name: "wal: reads ignore the write-ahead log", file: "internal/live/live.go", edit: edit{`query.Set("mode", "rw")`, "query.Set(\"mode\", \"ro\")\n\tquery.Set(\"immutable\", \"1\")"}, unit: "./internal/live/", scenario: "TestLiveWal"},
	{name: "capacity: a client that never reads a metadata response holds its slot", file: "internal/gohttp/run.go", edit: edit{"WriteTimeout:      config.RequestTimeout,", "WriteTimeout:      0,"}, unit: "./internal/gohttp/"},
	{name: "logging: request paths are logged", file: "internal/gohttp/app.go", edit: edit{`slog.String("route", found.name)`, `slog.String("route", r.URL.RequestURI())`}, unit: "./internal/gohttp/", scenario: "TestSensitiveValues"},
}

func copyModule(t *testing.T, destination string) {
	t.Helper()
	source, err := filepath.Abs("../..")
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range []string{"go.mod", "go.sum", "cmd", "internal", "e2e/httpruntime"} {
		root := filepath.Join(source, entry)
		walk := func(path string, directory fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			relative, _ := filepath.Rel(source, path)
			target := filepath.Join(destination, relative)
			if directory.IsDir() {
				return os.MkdirAll(target, 0o700)
			}
			data, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			return os.WriteFile(target, data, 0o600)
		}
		if info, err := os.Stat(root); err == nil && !info.IsDir() {
			data, _ := os.ReadFile(root)
			if err := os.WriteFile(filepath.Join(destination, entry), data, 0o600); err != nil {
				t.Fatal(err)
			}
			continue
		}
		if err := filepath.WalkDir(root, walk); err != nil {
			t.Fatal(err)
		}
	}
}

func TestMutantsAreDetected(t *testing.T) {
	for _, candidate := range mutants {
		t.Run(candidate.name, func(t *testing.T) {
			t.Parallel()
			directory := t.TempDir()
			copyModule(t, directory)
			path := filepath.Join(directory, candidate.file)
			original, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if strings.Count(string(original), candidate.edit.old) != 1 {
				t.Fatalf("the mutation target occurs %d times", strings.Count(string(original), candidate.edit.old))
			}
			if err := os.WriteFile(path, []byte(strings.Replace(string(original), candidate.edit.old, candidate.edit.new, 1)), 0o600); err != nil {
				t.Fatal(err)
			}
			if build := exec.Command("go", "build", "./..."); true {
				build.Dir = directory
				if output, err := build.CombinedOutput(); err != nil {
					t.Fatalf("the mutant does not compile, which proves nothing: %s", output)
				}
			}
			var detections []string
			if candidate.unit != "" {
				detections = append(detections, runMutantTests(t, directory, "./"+strings.TrimPrefix(candidate.unit, "./"), "", false))
			}
			if candidate.scenario != "" {
				detections = append(detections, runMutantTests(t, directory, "./e2e/httpruntime/", candidate.scenario, true))
			}
			for _, detected := range detections {
				if detected != "" {
					return
				}
			}
			t.Fatal("no assertion failed for this mutant")
		})
	}
}

func runMutantTests(t *testing.T, directory, packagePath, scenario string, tagged bool) string {
	t.Helper()
	arguments := []string{"test", "-count=1"}
	if tagged {
		arguments = append(arguments, "-tags", "e2e", "-run", scenario)
	}
	arguments = append(arguments, packagePath)
	context, cancel := context.WithTimeout(context.Background(), 6*time.Minute)
	defer cancel()
	command := exec.CommandContext(context, "go", arguments...)
	command.Dir = directory
	var output bytes.Buffer
	command.Stdout, command.Stderr = &output, &output
	err := command.Run()
	text := output.String()
	if err == nil {
		return ""
	}
	if strings.Contains(text, "build failed") || strings.Contains(text, "[setup failed]") || !strings.Contains(text, "--- FAIL") && !strings.Contains(text, "panic:") {
		t.Fatalf("the run failed without an assertion failing:\n%s", tail(text))
	}
	return "detected"
}

func tail(text string) string {
	if len(text) > 2000 {
		return text[len(text)-2000:]
	}
	return text
}
