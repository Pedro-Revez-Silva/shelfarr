package safeopen

import (
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

func TestRegularOpensOnlyRegularFilesWithoutBlocking(t *testing.T) {
	dir := t.TempDir()
	regular := filepath.Join(dir, "regular")
	if err := os.WriteFile(regular, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	fifo := filepath.Join(dir, "fifo")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "link")
	if err := os.Symlink(regular, link); err != nil {
		t.Fatal(err)
	}
	file, err := Regular(regular)
	if err != nil {
		t.Fatal(err)
	}
	file.Close()
	done := make(chan error, 3)
	go func() { _, err := Regular(fifo); done <- err }()
	go func() { _, err := Regular(link); done <- err }()
	go func() { _, err := Regular(dir); done <- err }()
	for range 3 {
		select {
		case err := <-done:
			if err == nil {
				t.Fatal("non-regular entry opened")
			}
		case <-time.After(5 * time.Second):
			t.Fatal("open blocked")
		}
	}
	if _, err := Regular(filepath.Join(dir, "absent")); err == nil || errors.Is(err, ErrNotRegular) {
		t.Fatalf("absent: %v", err)
	}
}
