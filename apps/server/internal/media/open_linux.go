//go:build linux

package media

import (
	"errors"
	"os"
	"strings"
	"syscall"

	"golang.org/x/sys/unix"
)

var (
	ErrUnavailable    = errors.New("media file is unavailable")
	ErrOutsideRoot    = errors.New("media file is outside its root")
	ErrNoPinnedOpen   = errors.New("kernel does not support confined opens")
	ErrNotRegularFile = errors.New("media entry is not a regular file")
)

func relative(root, path string) (string, bool) {
	prefix := strings.TrimRight(root, "/") + "/"
	if !strings.HasPrefix(path, prefix) || len(path) == len(prefix) {
		return "", false
	}
	return path[len(prefix):], true
}

func OpenPinned(root, path string) (*os.File, error) {
	name, inside := relative(root, path)
	if !inside {
		return nil, ErrOutsideRoot
	}
	directory, err := unix.Open(root, unix.O_PATH|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, ErrUnavailable
	}
	defer unix.Close(directory)
	descriptor, err := unix.Openat2(directory, name, &unix.OpenHow{
		Flags:   unix.O_RDONLY | unix.O_CLOEXEC | unix.O_NONBLOCK,
		Resolve: unix.RESOLVE_BENEATH | unix.RESOLVE_NO_SYMLINKS | unix.RESOLVE_NO_MAGICLINKS,
	})
	if errors.Is(err, syscall.ENOSYS) {
		return nil, ErrNoPinnedOpen
	}
	if err != nil {
		return nil, ErrUnavailable
	}
	var status unix.Stat_t
	if err := unix.Fstat(descriptor, &status); err != nil || status.Mode&unix.S_IFMT != unix.S_IFREG {
		unix.Close(descriptor)
		return nil, ErrNotRegularFile
	}
	if err := unix.SetNonblock(descriptor, false); err != nil {
		unix.Close(descriptor)
		return nil, ErrUnavailable
	}
	return os.NewFile(uintptr(descriptor), "media"), nil
}

func ConfinedOpenSupported() bool {
	directory, err := unix.Open("/", unix.O_PATH|unix.O_DIRECTORY|unix.O_CLOEXEC, 0)
	if err != nil {
		return false
	}
	defer unix.Close(directory)
	descriptor, err := unix.Openat2(directory, ".", &unix.OpenHow{Flags: unix.O_PATH | unix.O_CLOEXEC, Resolve: unix.RESOLVE_BENEATH})
	if err != nil {
		return false
	}
	unix.Close(descriptor)
	return true
}
