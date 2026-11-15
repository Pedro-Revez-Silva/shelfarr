//go:build !unix

package wfstore

import (
	"errors"
	"os"
)

const noFollow = 0

var errLockHeld = errors.New("lock held")

func lockExclusive(file *os.File) error {
	return errors.New("exclusive ownership needs a unix kernel lock")
}
