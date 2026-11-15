//go:build unix

package wfstore

import (
	"errors"
	"os"
	"syscall"
)

const noFollow = syscall.O_NOFOLLOW

var errLockHeld = errors.New("lock held")

func lockExclusive(file *os.File) error {
	err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
	if errors.Is(err, syscall.EWOULDBLOCK) {
		return errLockHeld
	}
	return err
}
