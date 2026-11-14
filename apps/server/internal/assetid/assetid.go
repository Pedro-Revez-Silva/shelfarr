package assetid

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"math/big"
	"strconv"
	"strings"
)

type Stat struct {
	Device uint64
	Inode  uint64
	Size   int64
	Mtime  *big.Rat
	Ctime  *big.Rat
}

type Input struct {
	BookID        int64
	StoredPath    string
	CanonicalPath string
	Stat          Stat
}

var ErrInvalidRational = errors.New("invalid rational timestamp")

func FormatRational(value *big.Rat) string {
	return value.Num().String() + "/" + value.Denom().String()
}

func ParseRational(text string) (*big.Rat, error) {
	numerator, denominator, found := strings.Cut(text, "/")
	if !found {
		return nil, ErrInvalidRational
	}
	top, ok := new(big.Int).SetString(numerator, 10)
	if !ok {
		return nil, ErrInvalidRational
	}
	bottom, ok := new(big.Int).SetString(denominator, 10)
	if !ok || bottom.Sign() <= 0 {
		return nil, ErrInvalidRational
	}
	return new(big.Rat).SetFrac(top, bottom), nil
}

func FromTimespec(seconds, nanoseconds int64) *big.Rat {
	total := new(big.Int).Mul(big.NewInt(seconds), big.NewInt(1_000_000_000))
	total.Add(total, big.NewInt(nanoseconds))
	return new(big.Rat).SetFrac(total, big.NewInt(1_000_000_000))
}

func ID(input Input) string {
	fields := []string{
		strconv.FormatInt(input.BookID, 10),
		input.StoredPath,
		input.CanonicalPath,
		strconv.FormatUint(input.Stat.Device, 10),
		strconv.FormatUint(input.Stat.Inode, 10),
		strconv.FormatInt(input.Stat.Size, 10),
		FormatRational(input.Stat.Mtime),
		FormatRational(input.Stat.Ctime),
	}
	sum := sha256.Sum256([]byte(strings.Join(fields, "\x00")))
	return hex.EncodeToString(sum[:])
}
