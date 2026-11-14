//go:build !linux

package assetid

import (
	"errors"
	"os"
)

var ErrUnsupportedStat = errors.New("file status is only available on linux")

func StatOf(os.FileInfo) (Stat, error) {
	return Stat{}, ErrUnsupportedStat
}
