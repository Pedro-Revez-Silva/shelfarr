//go:build linux

package assetid

import (
	"errors"
	"os"
	"syscall"
)

var ErrUnsupportedStat = errors.New("file status is not available")

func StatOf(info os.FileInfo) (Stat, error) {
	raw, ok := info.Sys().(*syscall.Stat_t)
	if !ok || raw.Size < 0 {
		return Stat{}, ErrUnsupportedStat
	}
	return Stat{
		Device: uint64(raw.Dev),
		Inode:  uint64(raw.Ino),
		Size:   raw.Size,
		Mtime:  FromTimespec(int64(raw.Mtim.Sec), int64(raw.Mtim.Nsec)),
		Ctime:  FromTimespec(int64(raw.Ctim.Sec), int64(raw.Ctim.Nsec)),
	}, nil
}
