//go:build linux

package bookfile

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"golang.org/x/sys/unix"
)

var (
	ErrRootRefused = errors.New("library root is not a private directory inside the disposable directory")
	ErrRootChanged = errors.New("library root changed")
	ErrExists      = errors.New("a file already exists at the destination")
	ErrUnsafe      = errors.New("destination directory is not safe")
	ErrStaging     = errors.New("anonymous staging is not supported here")
)

const (
	confined     = unix.RESOLVE_BENEATH | unix.RESOLVE_NO_SYMLINKS | unix.RESOLVE_NO_MAGICLINKS | unix.RESOLVE_NO_XDEV
	directoryAll = unix.O_RDONLY | unix.O_DIRECTORY | unix.O_CLOEXEC
	folderMode   = 0o755
	fileMode     = 0o644
)

type Identity struct {
	Device uint64
	Inode  uint64
}

type Placement struct {
	Folders []string
	Name    string
}

func (p Placement) Relative() string {
	return filepath.Join(append(append([]string{}, p.Folders...), p.Name)...)
}

type Root struct {
	workdir  string
	relative string
	identity Identity
}

func OpenRoot(workdir, path string) (*Root, error) {
	realWorkdir, err := filepath.EvalSymlinks(workdir)
	if err != nil || !filepath.IsAbs(path) || filepath.Clean(path) != path || strings.ContainsRune(path, 0) {
		return nil, ErrRootRefused
	}
	relative, inside := strings.CutPrefix(path, realWorkdir+"/")
	if !inside || relative == "" {
		return nil, ErrRootRefused
	}
	fd, identity, err := openConfined(realWorkdir, relative)
	if err != nil {
		return nil, ErrRootRefused
	}
	unix.Close(fd)
	return &Root{workdir: realWorkdir, relative: relative, identity: identity}, nil
}

func openConfined(workdir, relative string) (int, Identity, error) {
	base, err := unix.Open(workdir, unix.O_PATH|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return -1, Identity{}, err
	}
	defer unix.Close(base)
	fd, err := unix.Openat2(base, relative, &unix.OpenHow{Flags: directoryAll, Resolve: confined})
	if err != nil {
		return -1, Identity{}, err
	}
	identity, err := privateDirectory(fd)
	if err != nil {
		unix.Close(fd)
		return -1, Identity{}, err
	}
	return fd, identity, nil
}

func privateDirectory(fd int) (Identity, error) {
	var status unix.Stat_t
	if err := unix.Fstat(fd, &status); err != nil {
		return Identity{}, err
	}
	if status.Mode&unix.S_IFMT != unix.S_IFDIR || status.Uid != uint32(os.Getuid()) || status.Mode&0o022 != 0 {
		return Identity{}, ErrUnsafe
	}
	return Identity{Device: uint64(status.Dev), Inode: uint64(status.Ino)}, nil
}

func (r *Root) open() (int, error) {
	fd, identity, err := openConfined(r.workdir, r.relative)
	if err != nil {
		return -1, ErrRootChanged
	}
	if identity != r.identity {
		unix.Close(fd)
		return -1, ErrRootChanged
	}
	return fd, nil
}

type Staged struct {
	File     *os.File
	Identity Identity
	Size     int64
}

func (r *Root) Stage() (*Staged, error) {
	root, err := r.open()
	if err != nil {
		return nil, err
	}
	defer unix.Close(root)
	fd, err := unix.Openat(root, ".", unix.O_TMPFILE|unix.O_RDWR|unix.O_CLOEXEC, fileMode)
	if err != nil {
		return nil, ErrStaging
	}
	return &Staged{File: os.NewFile(uintptr(fd), "staged-book")}, nil
}

func (s *Staged) Seal() error {
	if err := s.File.Sync(); err != nil {
		return err
	}
	var status unix.Stat_t
	if err := unix.Fstat(int(s.File.Fd()), &status); err != nil {
		return err
	}
	if status.Mode&unix.S_IFMT != unix.S_IFREG || status.Nlink != 0 {
		return ErrStaging
	}
	s.Identity = Identity{Device: uint64(status.Dev), Inode: uint64(status.Ino)}
	s.Size = status.Size
	return nil
}

func (s *Staged) Close() { s.File.Close() }

func (r *Root) folder(placement Placement, create bool) (int, error) {
	current, err := r.open()
	if err != nil {
		return -1, err
	}
	for _, name := range placement.Folders {
		next, err := r.child(current, name, create)
		unix.Close(current)
		if err != nil {
			return -1, err
		}
		current = next
	}
	return current, nil
}

func (r *Root) child(parent int, name string, create bool) (int, error) {
	if create {
		if err := unix.Mkdirat(parent, name, folderMode); err != nil && !errors.Is(err, unix.EEXIST) {
			return -1, err
		}
	}
	next, err := unix.Openat2(parent, name, &unix.OpenHow{Flags: directoryAll, Resolve: confined})
	if errors.Is(err, unix.ENOENT) {
		return -1, err
	}
	if err != nil {
		return -1, ErrUnsafe
	}
	if _, err := privateDirectory(next); err != nil {
		unix.Close(next)
		return -1, ErrUnsafe
	}
	if create {
		if err := unix.Fsync(parent); err != nil {
			unix.Close(next)
			return -1, err
		}
	}
	return next, nil
}

type Published struct {
	Identity Identity
	Linked   bool
}

func (r *Root) Publish(staged *Staged, placement Placement, digest []byte) (Published, error) {
	folder, err := r.folder(placement, true)
	if err != nil {
		return Published{}, err
	}
	defer unix.Close(folder)
	source := "/proc/self/fd/" + strconv.Itoa(int(staged.File.Fd()))
	err = unix.Linkat(unix.AT_FDCWD, source, folder, placement.Name, unix.AT_SYMLINK_FOLLOW)
	if errors.Is(err, unix.EEXIST) {
		return identical(folder, placement.Name, staged.Size, digest)
	}
	if err != nil {
		return Published{}, err
	}
	return Published{Identity: staged.Identity, Linked: true}, unix.Fsync(folder)
}

func identical(folder int, name string, size int64, digest []byte) (Published, error) {
	fd, err := unix.Openat(folder, name, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if err != nil {
		return Published{}, ErrExists
	}
	file := os.NewFile(uintptr(fd), "library-file")
	defer file.Close()
	var status unix.Stat_t
	if err := unix.Fstat(fd, &status); err != nil {
		return Published{}, ErrExists
	}
	if status.Mode&unix.S_IFMT != unix.S_IFREG || status.Nlink != 1 || status.Uid != uint32(os.Getuid()) || status.Size != size {
		return Published{}, ErrExists
	}
	hash := sha256.New()
	if _, err := io.Copy(hash, io.LimitReader(file, size+1)); err != nil || !bytes.Equal(hash.Sum(nil), digest) {
		return Published{}, ErrExists
	}
	return Published{Identity: Identity{Device: uint64(status.Dev), Inode: uint64(status.Ino)}}, unix.Fsync(folder)
}

func (r *Root) Identify(placement Placement) (Identity, bool, error) {
	folder, err := r.folder(placement, false)
	if errors.Is(err, unix.ENOENT) {
		return Identity{}, false, nil
	}
	if err != nil {
		return Identity{}, false, err
	}
	defer unix.Close(folder)
	var status unix.Stat_t
	err = unix.Fstatat(folder, placement.Name, &status, unix.AT_SYMLINK_NOFOLLOW)
	if errors.Is(err, unix.ENOENT) {
		return Identity{}, false, nil
	}
	if err != nil {
		return Identity{}, false, err
	}
	if status.Mode&unix.S_IFMT != unix.S_IFREG {
		return Identity{}, true, ErrUnsafe
	}
	return Identity{Device: uint64(status.Dev), Inode: uint64(status.Ino)}, true, nil
}

func (r *Root) Remove(placement Placement, linked Identity) error {
	folder, err := r.folder(placement, false)
	if err != nil {
		return err
	}
	defer unix.Close(folder)
	var status unix.Stat_t
	if err := unix.Fstatat(folder, placement.Name, &status, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		return err
	}
	if status.Mode&unix.S_IFMT != unix.S_IFREG || (Identity{Device: uint64(status.Dev), Inode: uint64(status.Ino)}) != linked {
		return ErrExists
	}
	if err := unix.Unlinkat(folder, placement.Name, 0); err != nil {
		return err
	}
	return unix.Fsync(folder)
}
