package assetid

import (
	"crypto/sha256"
	"encoding/hex"
	"math/big"
	"testing"
)

func TestFormatRationalMatchesRubyRationalToS(t *testing.T) {
	cases := []struct {
		numerator, denominator int64
		want                   string
	}{
		{5, 1, "5/1"},
		{0, 1, "0/1"},
		{-3, 2, "-3/2"},
		{2, 6, "1/3"},
		{-14, 6, "-7/3"},
		{3_000_000_000, 1_000_000_000, "3/1"},
	}
	for _, testCase := range cases {
		got := FormatRational(big.NewRat(testCase.numerator, testCase.denominator))
		if got != testCase.want {
			t.Errorf("%d/%d = %q, want %q", testCase.numerator, testCase.denominator, got, testCase.want)
		}
	}
}

func TestFromTimespec(t *testing.T) {
	cases := []struct {
		seconds, nanoseconds int64
		want                 string
	}{
		{1_700_000_000, 123_456_789, "1700000000123456789/1000000000"},
		{-2, 500_000_000, "-3/2"},
		{-1, 999_999_999, "-1/1000000000"},
		{0, 0, "0/1"},
		{7, 0, "7/1"},
	}
	for _, testCase := range cases {
		if got := FormatRational(FromTimespec(testCase.seconds, testCase.nanoseconds)); got != testCase.want {
			t.Errorf("%d.%09d = %q, want %q", testCase.seconds, testCase.nanoseconds, got, testCase.want)
		}
	}
}

func TestParseRationalRejects(t *testing.T) {
	for _, text := range []string{"", "5", "5/", "/5", "a/b", "1/0", "1/-2", "1.5/2", "1/2/3"} {
		if _, err := ParseRational(text); err == nil {
			t.Errorf("%q accepted", text)
		}
	}
}

func TestIDJoinsFieldsWithNulSeparatorsInOrder(t *testing.T) {
	input := Input{BookID: 42, StoredPath: "/a//b", CanonicalPath: "/a/b", Stat: Stat{
		Device: 1 << 63, Inode: 1<<64 - 1, Size: 5, Mtime: big.NewRat(-3, 2), Ctime: big.NewRat(7, 1),
	}}
	joined := "42\x00/a//b\x00/a/b\x009223372036854775808\x0018446744073709551615\x005\x00-3/2\x007/1"
	sum := sha256.Sum256([]byte(joined))
	if got := ID(input); got != hex.EncodeToString(sum[:]) {
		t.Fatalf("id = %s", got)
	}
}

func TestIDDistinguishesEveryField(t *testing.T) {
	base := Input{BookID: 1, StoredPath: "/s", CanonicalPath: "/c", Stat: Stat{Device: 2, Inode: 3, Size: 4, Mtime: big.NewRat(5, 1), Ctime: big.NewRat(6, 1)}}
	variants := map[string]func(Input) Input{
		"book":      func(i Input) Input { i.BookID = 2; return i },
		"stored":    func(i Input) Input { i.StoredPath = "/s2"; return i },
		"canonical": func(i Input) Input { i.CanonicalPath = "/c2"; return i },
		"device":    func(i Input) Input { i.Stat.Device = 3; return i },
		"inode":     func(i Input) Input { i.Stat.Inode = 4; return i },
		"size":      func(i Input) Input { i.Stat.Size = 5; return i },
		"mtime":     func(i Input) Input { i.Stat.Mtime = big.NewRat(11, 2); return i },
		"ctime":     func(i Input) Input { i.Stat.Ctime = big.NewRat(13, 2); return i },
	}
	original := ID(base)
	for name, change := range variants {
		if ID(change(base)) == original {
			t.Errorf("changing %s kept the id", name)
		}
	}
}
