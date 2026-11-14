package safeopen

import (
	"errors"
	"os"
	"syscall"
)

var ErrNotRegular = errors.New("not a regular file")

func Regular(path string) (*os.File, error) {
	file, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NONBLOCK|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() {
		file.Close()
		return nil, ErrNotRegular
	}
	return file, nil
}
