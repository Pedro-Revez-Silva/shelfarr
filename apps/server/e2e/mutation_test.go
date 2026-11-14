//go:build e2e

package e2e

import (
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"syscall"
	"testing"
)

type edit struct {
	old   string
	new   string
	count int
}

type mutation struct {
	name  string
	file  string
	edits []edit
	args  []string
	setup func(*variant)
}

func one(old, replacement string) []edit {
	return []edit{{old: old, new: replacement, count: 1}}
}

var defaultArguments = []string{"--legacy-sha1"}

var mutations = []mutation{
	{name: "identity: separator is not NUL", file: "internal/assetid/assetid.go", edits: one(`strings.Join(fields, "\x00")`, `strings.Join(fields, "\n")`)},
	{name: "identity: fractional seconds dropped", file: "internal/assetid/assetid.go", edits: one(`total.Add(total, big.NewInt(nanoseconds))`, `total.Add(total, big.NewInt(0))`)},
	{name: "identity: timestamps as decimals", file: "internal/assetid/assetid.go", edits: one(`return value.Num().String() + "/" + value.Denom().String()`, `return value.FloatString(3)`)},
	{name: "identity: change time omitted", file: "internal/assetid/assetid.go", edits: one("\t\tFormatRational(input.Stat.Ctime),\n", "")},
	{name: "identity: inode as signed integer", file: "internal/assetid/assetid.go", edits: one(`strconv.FormatUint(input.Stat.Inode, 10)`, `strconv.FormatInt(int64(input.Stat.Inode), 10)`)},
	{name: "identity: device as signed integer", file: "internal/assetid/assetid.go", edits: one(`strconv.FormatUint(input.Stat.Device, 10)`, `strconv.FormatInt(int64(input.Stat.Device), 10)`)},
	{name: "identity: stored path replaced by canonical path", file: "internal/assetid/assetid.go", edits: one("input.StoredPath,\n\t\tinput.CanonicalPath,", "input.CanonicalPath,\n\t\tinput.CanonicalPath,")},
	{name: "identity: library passes canonical path as stored path", file: "internal/library/assets.go", edits: one(`StoredPath: bookPath, CanonicalPath`, `StoredPath: located.target, CanonicalPath`)},
	{name: "crypto: primary key derived with sha1", file: "internal/arcrypt/arcrypt.go", edits: []edit{
		{`}{{SchemeSHA256, sha256.New}}`, `}{{SchemeSHA256, sha1.New}}`, 1},
		{"type Kind string", "var _ = sha256.New\n\ntype Kind string", 1},
	}},
	{name: "crypto: compression flag ignored", file: "internal/arcrypt/arcrypt.go", edits: one(`result.compressed = truthy(parsed.Headers["c"])`, `result.compressed = false`)},
	{name: "crypto: inflation unbounded", file: "internal/arcrypt/arcrypt.go", setup: addBoundsCases, edits: []edit{
		{`io.LimitReader(reader, MaxPlaintextBytes+1)`, `reader`, 1},
		{"if len(inflated) > MaxPlaintextBytes {\n\t\treturn nil, fail(KindLimit)\n\t}", "", 1},
	}},
	{name: "crypto: envelope size unbounded", file: "internal/arcrypt/arcrypt.go", setup: addBoundsCases, edits: one(`if len(data) > MaxEnvelopeBytes {`, `if false {`)},
	{name: "crypto: legacy derivation always on", file: "internal/arcrypt/arcrypt.go", args: []string{}, edits: one(`if options.LegacySHA1 {`, `if true {`)},
	{name: "crypto: newline tolerated in base64", file: "internal/arcrypt/arcrypt.go", edits: one(`strings.ContainsAny(value, "\r\n")`, `false`)},
	{name: "password: any password accepted", file: "internal/account/account.go", edits: one(`return bcrypt.CompareHashAndPassword([]byte(digest), []byte(candidate)) == nil, nil`, `return bcrypt.CompareHashAndPassword([]byte(digest), []byte(candidate)) == nil || true, nil`)},
	{name: "password: candidate trimmed", file: "internal/account/account.go", edits: one(`[]byte(candidate)) == nil, nil`, `[]byte(strings.TrimSpace(candidate))) == nil, nil`)},
	{name: "password: empty password accepted and candidate lower-cased", file: "internal/account/account.go", edits: one(`[]byte(candidate)) == nil, nil`, `[]byte(strings.ToLower(candidate))) == nil || candidate == "", nil`)},
	{name: "password: cost ceiling removed", file: "internal/account/account.go", setup: costBomb, edits: one(`if cost > MaxBcryptCost {`, `if cost > MaxBcryptCost && false {`)},
	{name: "bundle: manifest opened without refusing non-regular files", file: "internal/safeopen/safeopen.go", setup: fifoManifest, edits: []edit{
		{`os.O_RDONLY|syscall.O_NONBLOCK|syscall.O_NOFOLLOW|syscall.O_CLOEXEC`, `os.O_RDONLY|syscall.O_CLOEXEC`, 1},
		{`!info.Mode().IsRegular()`, `!info.Mode().IsRegular() && false`, 1},
	}},
	{name: "bundle: trailing data after the first document accepted", file: "internal/bundle/open.go", setup: trailingBracket, edits: one(`!errors.Is(err, io.EOF)`, `!errors.Is(err, io.EOF) && false`)},
	{name: "token: revocation ignored", file: "internal/account/account.go", edits: one(`if token.RevokedAt.Valid {`, `if false {`)},
	{name: "token: expiry ignored", file: "internal/account/account.go", edits: one(`if !expiry.After(now) {`, `if !expiry.After(now) && false {`)},
	{name: "token: deleted account allowed", file: "internal/account/account.go", edits: one(`user == nil || user.Deleted`, `user == nil`)},
	{name: "token: adoption side effect silently ignored", file: "internal/account/account.go", edits: one(`if token.ReplacesID.Valid {`, `if false {`)},
	{name: "projection: scope check skipped", file: "internal/consumer/consumer.go", edits: one(`if !principal.HasScope("library:read") {`, `if false {`)},
	{name: "projection: comics listed", file: "internal/consumer/consumer.go", edits: one(`[]int{store.BookTypeEbook, store.BookTypeAudiobook}`, `[]int{store.BookTypeEbook, store.BookTypeAudiobook, store.BookTypeComicbook}`)},
	{name: "projection: description cut by bytes", file: "internal/consumer/consumer.go", edits: one(`return string(runes), nil`, `return value.String[:descriptionLimit], nil`)},
	{name: "projection: insecure cover allowed", file: "internal/consumer/consumer.go", edits: one(`!strings.EqualFold(parsed.Scheme, "https")`, `parsed.Scheme == ""`)},
	{name: "projection: cover credentials allowed", file: "internal/consumer/consumer.go", edits: one(`if parsed.Host == "" || parsed.User != nil {`, `if parsed.Host == "" {`)},
	{name: "projection: progress implies no status", file: "internal/consumer/consumer.go", edits: one(`if hasProgress {
		return "in_progress"`, `if false {
		return "in_progress"`)},
	{name: "projection: unknown observation becomes empty", file: "internal/consumer/consumer.go", edits: one(`if progress.ObservedAt.Valid {`, `if true {`)},
	{name: "projection: null position becomes zero", file: "internal/consumer/consumer.go", edits: one(`if progress.PositionSeconds.Valid {`, `if true {`)},
	{name: "isolation: progress not scoped to the account", file: "internal/store/store.go", edits: one(`FROM consumer_progresses WHERE user_id = ?`, `FROM consumer_progresses WHERE ? IS NOT NULL`)},
	{name: "isolation: reading state not scoped to the account", file: "internal/store/store.go", edits: one(`FROM consumer_reading_states WHERE user_id = ?`, `FROM consumer_reading_states WHERE ? IS NOT NULL`)},
	{name: "isolation: database opened writable with a journal", file: "internal/store/store.go", edits: []edit{
		{`query.Set("mode", "ro")`, `query.Set("mode", "rwc")`, 1},
		{`query.Set("immutable", "1")`, `query.Set("cache", "private")`, 1},
		{`query.Add("_pragma", "query_only(1)")`, `query.Add("_pragma", "journal_mode(WAL)")`, 1},
	}},
	{name: "isolation: checker leaves a journal beside the database", file: "internal/compat/compat.go", edits: []edit{
		{`func (r *runner) checkSchema(ctx context.Context) {`, "func (r *runner) checkSchema(ctx context.Context) {\n\tos.WriteFile(r.bundle.DatabasePath()+\"-journal\", nil, 0o600)", 1},
		{`"math/big"`, "\"math/big\"\n\t\"os\"", 1},
	}},
	{name: "projection: blank paths count as acquired", file: "internal/store/store.go", edits: []edit{{` AND TRIM(file_path) <> ''`, ``, 2}}},
	{name: "projection: timestamps rounded instead of truncated", file: "internal/store/timestamp.go", edits: one(`utc.Nanosecond()/1_000_000)`, `(utc.Nanosecond()+500_000)/1_000_000)`)},
	{name: "library: plain string ordering", file: "internal/library/natural.go", edits: one(`return compareKeys(keys[paths[i]], keys[paths[j]]) < 0`, `return paths[i] < paths[j]`)},
	{name: "library: sibling directory prefix counts as inside the root", file: "internal/library/roots.go", edits: one(`prefix += "/"`, `prefix += ""`)},
	{name: "library: symbolic links not resolved", file: "internal/library/assets.go", edits: one(`target, err := filepath.EvalSymlinks(expanded)`, `target, err := expanded, error(nil)`)},
	{name: "library: hidden files listed", file: "internal/library/assets.go", edits: one(`if strings.HasPrefix(entry.Name(), ".") {`, `if false {`)},
	{name: "library: extension compared case-sensitively", file: "internal/library/assets.go", edits: one(`return strings.ToLower(strings.TrimPrefix(rubyExt(path), "."))`, `return strings.TrimPrefix(rubyExt(path), ".")`)},
	{name: "library: a book at the library root is listed", file: "internal/library/assets.go", edits: one(`if located.target == located.root {`, `if false {`)},
}

func copyModule(t *testing.T, destination string) {
	t.Helper()
	err := filepath.WalkDir(moduleDir, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		relative, _ := filepath.Rel(moduleDir, path)
		top := strings.Split(relative, string(filepath.Separator))[0]
		if entry.IsDir() {
			if relative != "." && top != "cmd" && top != "internal" {
				return fs.SkipDir
			}
			return os.MkdirAll(filepath.Join(destination, relative), 0o755)
		}
		if strings.HasSuffix(path, "_test.go") || (relative != "go.mod" && relative != "go.sum" && top != "cmd" && top != "internal") {
			return nil
		}
		return os.WriteFile(filepath.Join(destination, relative), readFile(t, path), 0o644)
	})
	if err != nil {
		t.Fatal(err)
	}
}

func buildMutant(t *testing.T, scratch string, spec mutation) string {
	t.Helper()
	source := filepath.Join(scratch, "source")
	copyModule(t, source)
	target := filepath.Join(source, filepath.FromSlash(spec.file))
	text := string(readFile(t, target))
	for _, change := range spec.edits {
		if got := strings.Count(text, change.old); got != change.count {
			t.Fatalf("mutation text occurs %d times in %s, want %d: %q", got, spec.file, change.count, change.old)
		}
		text = strings.ReplaceAll(text, change.old, change.new)
	}
	if err := os.WriteFile(target, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
	path, err := buildBinary(source, scratch, "mutant")
	if err != nil {
		t.Fatalf("mutant does not compile: %v", err)
	}
	return path
}

func signature(result outcome) any {
	type check struct {
		name     string
		failures string
	}
	var checks []check
	for _, entry := range result.report.Checks {
		checks = append(checks, check{entry.Name, entry.Status + "|" + strings.Join(entry.Failures, ",")})
	}
	return struct {
		code   int
		checks []check
	}{result.code, checks}
}

func TestMutantsAreKilled(t *testing.T) {
	var survivors []string
	var guard sync.Mutex
	t.Run("group", func(t *testing.T) {
		for _, spec := range mutations {
			t.Run(spec.name, func(t *testing.T) {
				t.Parallel()
				arguments := spec.args
				if arguments == nil {
					arguments = defaultArguments
				}
				scratch := t.TempDir()
				mutant := buildMutant(t, scratch, spec)
				current := newVariant(t)
				if spec.setup != nil {
					spec.setup(current)
				}
				reference := execute(t, binary, current.dir, arguments...)
				mutated := execute(t, mutant, current.dir, arguments...)
				if reflect.DeepEqual(signature(reference), signature(mutated)) {
					guard.Lock()
					survivors = append(survivors, spec.name)
					guard.Unlock()
					return
				}
				t.Logf("killed: exit %d, failing checks %v", mutated.code, mutated.failed())
			})
		}
	})
	if len(survivors) > 0 {
		t.Fatalf("%d mutants survived:\n%s", len(survivors), strings.Join(survivors, "\n"))
	}
}

func costBomb(v *variant) {
	v.editDatabase("UPDATE users SET password_digest = '$2a$31$' || substr(password_digest, 8) WHERE username = 'alice'")
	v.seal()
}

func fifoManifest(v *variant) {
	os.Remove(v.path("manifest.json"))
	if err := syscall.Mkfifo(v.path("manifest.json"), 0o600); err != nil {
		v.t.Fatal(err)
	}
}

func trailingBracket(v *variant) {
	data := readFile(v.t, v.path("manifest.json"))
	writeFile(v.t, v.path("manifest.json"), append(data, ']'), 0o640)
}
