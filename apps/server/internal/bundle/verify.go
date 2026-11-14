package bundle

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/safeopen"
)

type ctxReader struct {
	ctx    context.Context
	source io.Reader
}

func (r ctxReader) Read(buffer []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.source.Read(buffer)
}

func hashFile(ctx context.Context, path string, limit int64) (string, int64, error) {
	file, err := safeopen.Regular(path)
	if err != nil {
		return "", 0, fail("unreadable", "")
	}
	defer file.Close()
	digest := sha256.New()
	written, err := io.Copy(digest, io.LimitReader(ctxReader{ctx, file}, limit+1))
	if err != nil {
		if ctx.Err() != nil {
			return "", 0, ctx.Err()
		}
		return "", 0, fail("unreadable", "")
	}
	if written > limit {
		return "", 0, fail("too-large", "")
	}
	return hex.EncodeToString(digest.Sum(nil)), written, nil
}

func (b *Bundle) treeRoots() map[string]bool {
	roots := map[string]bool{}
	for _, tree := range b.Manifest.ExternalTrees {
		roots[tree.Root] = true
	}
	return roots
}

func (b *Bundle) Verify(ctx context.Context) error {
	for name, entry := range b.Manifest.Files {
		if err := verifyFile(ctx, filepath.Join(b.Dir, filepath.FromSlash(name)), name, entry, limitFor(b, name)); err != nil {
			return err
		}
	}
	if err := b.verifyExtras(); err != nil {
		return err
	}
	for _, tree := range b.Manifest.ExternalTrees {
		if err := verifyTree(ctx, tree); err != nil {
			return err
		}
	}
	return nil
}

func limitFor(b *Bundle, name string) int64 {
	if name == b.Manifest.Database.Path {
		return MaxDatabaseBytes
	}
	return MaxFileBytes
}

func verifyFile(ctx context.Context, path, label string, entry FileEntry, limit int64) error {
	info, err := os.Lstat(path)
	if err != nil {
		return fail("missing", subject(label))
	}
	if !info.Mode().IsRegular() {
		return fail("not-a-regular-file", subject(label))
	}
	if info.Size() != entry.Size {
		return fail("size-mismatch", subject(label))
	}
	sum, _, err := hashFile(ctx, path, limit)
	if err != nil {
		return relabel(err, subject(label))
	}
	if sum != entry.SHA256 {
		return fail("hash-mismatch", subject(label))
	}
	return nil
}

func (b *Bundle) verifyExtras() error {
	roots := b.treeRoots()
	count := 0
	return filepath.WalkDir(b.Dir, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return fail("unreadable", "")
		}
		if roots[path] {
			return fs.SkipDir
		}
		if path == b.Dir {
			return nil
		}
		count++
		if count > MaxEntries {
			return fail("too-many-entries", "")
		}
		relative, _ := filepath.Rel(b.Dir, path)
		relative = filepath.ToSlash(relative)
		if entry.IsDir() {
			return nil
		}
		if !entry.Type().IsRegular() {
			return fail("unexpected-entry", "")
		}
		if _, listed := b.Manifest.Files[relative]; !listed && relative != "manifest.json" {
			return fail("unexpected-file", "")
		}
		return nil
	})
}

func verifyTree(ctx context.Context, tree Tree) error {
	info, err := os.Lstat(tree.Root)
	if err != nil || !info.IsDir() {
		return fail("missing-tree", "")
	}
	for name, entry := range tree.Files {
		if err := verifyFile(ctx, filepath.Join(tree.Root, filepath.FromSlash(name)), "", entry, MaxFileBytes); err != nil {
			return err
		}
	}
	for name, target := range tree.Symlinks {
		actual, err := os.Readlink(filepath.Join(tree.Root, filepath.FromSlash(name)))
		if err != nil || actual != target {
			return fail("symlink-mismatch", "")
		}
	}
	count := 0
	return filepath.WalkDir(tree.Root, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return fail("unreadable", "")
		}
		if path == tree.Root {
			return nil
		}
		count++
		if count > MaxEntries {
			return fail("too-many-entries", "")
		}
		relative, _ := filepath.Rel(tree.Root, path)
		relative = filepath.ToSlash(relative)
		switch {
		case entry.IsDir():
			return nil
		case entry.Type()&fs.ModeSymlink != 0:
			if _, listed := tree.Symlinks[relative]; !listed {
				return fail("unexpected-symlink", "")
			}
		case entry.Type().IsRegular():
			if _, listed := tree.Files[relative]; !listed {
				return fail("unexpected-file", "")
			}
		default:
			return fail("unexpected-entry", "")
		}
		return nil
	})
}

type FileState struct {
	Kind    string
	Size    int64
	Mode    uint32
	MtimeNs int64
	CtimeNs int64
	Inode   uint64
	SHA256  string
}

type Snapshot map[string]FileState

func (b *Bundle) Snapshot(ctx context.Context) (Snapshot, error) {
	snapshot := Snapshot{}
	roots := []struct{ prefix, root string }{{"bundle:", b.Dir}}
	for _, tree := range b.Manifest.ExternalTrees {
		roots = append(roots, struct{ prefix, root string }{"tree:" + tree.Name + ":", tree.Root})
	}
	count := 0
	for _, entry := range roots {
		err := filepath.WalkDir(entry.root, func(path string, dirEntry fs.DirEntry, walkErr error) error {
			if walkErr != nil {
				return fail("unreadable", "")
			}
			if path != entry.root && entry.prefix == "bundle:" && b.treeRoots()[path] {
				return fs.SkipDir
			}
			count++
			if count > MaxEntries*2 {
				return fail("too-many-entries", "")
			}
			info, err := os.Lstat(path)
			if err != nil {
				return fail("unreadable", "")
			}
			relative, _ := filepath.Rel(entry.root, path)
			state, err := describeState(ctx, path, info)
			if err != nil {
				return err
			}
			snapshot[entry.prefix+filepath.ToSlash(relative)] = state
			return nil
		})
		if err != nil {
			return nil, err
		}
	}
	return snapshot, nil
}

func describeState(ctx context.Context, path string, info os.FileInfo) (FileState, error) {
	raw, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return FileState{}, fail("unreadable", "")
	}
	state := FileState{
		Kind: kindOf(info), Size: info.Size(), Mode: uint32(info.Mode()),
		MtimeNs: int64(raw.Mtim.Sec)*1_000_000_000 + int64(raw.Mtim.Nsec),
		CtimeNs: int64(raw.Ctim.Sec)*1_000_000_000 + int64(raw.Ctim.Nsec),
		Inode:   uint64(raw.Ino),
	}
	if info.Mode().IsRegular() {
		sum, _, err := hashFile(ctx, path, MaxFileBytes)
		if err != nil {
			return FileState{}, err
		}
		state.SHA256 = sum
	}
	return state, nil
}

func kindOf(info os.FileInfo) string {
	switch {
	case info.Mode().IsRegular():
		return "file"
	case info.IsDir():
		return "directory"
	case info.Mode()&os.ModeSymlink != 0:
		return "symlink"
	}
	return "other"
}

func (s Snapshot) Differences(after Snapshot) []string {
	var changes []string
	for name, before := range s {
		current, present := after[name]
		switch {
		case !present:
			changes = append(changes, "removed:"+name)
		case current != before:
			changes = append(changes, "changed:"+name)
		}
	}
	for name := range after {
		if _, present := s[name]; !present {
			changes = append(changes, "added:"+name)
		}
	}
	sort.Strings(changes)
	return changes
}

func IsSidecar(name string) bool {
	for _, suffix := range []string{"-wal", "-shm", "-journal"} {
		if strings.HasSuffix(name, suffix) {
			return true
		}
	}
	return false
}
