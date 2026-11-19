//go:build !linux

package wfstore

import (
	"os"
	"path/filepath"
)

func openBeneath(dir, relative string) (*os.File, error) {
	return os.OpenFile(filepath.Join(dir, relative), os.O_RDWR|os.O_CREATE|noFollow, 0o600)
}
