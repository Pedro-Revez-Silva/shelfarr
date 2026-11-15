//go:build unix

package ownership

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

var (
	ErrHeld       = errors.New("another process owns this domain")
	ErrPath       = errors.New("lock path is not usable")
	ErrNotRegular = errors.New("lock path is not a regular file")
)

type Lock struct {
	file *os.File
}

func Acquire(path string) (*Lock, error) {
	if !filepath.IsAbs(path) || strings.ContainsRune(path, 0) {
		return nil, ErrPath
	}
	file, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0o600)
	if err != nil {
		return nil, ErrPath
	}
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() {
		file.Close()
		return nil, ErrNotRegular
	}
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		file.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, ErrHeld
		}
		return nil, ErrPath
	}
	return &Lock{file: file}, nil
}

func (l *Lock) Release() error {
	return l.file.Close()
}
