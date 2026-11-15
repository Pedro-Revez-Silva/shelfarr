package media

import (
	"math"
	"strconv"
)

type Span struct {
	First int64
	Last  int64
}

func (s Span) Length() int64 { return max(s.Last-s.First+1, 0) }

func parseNumber(digits string) int64 {
	number, err := strconv.ParseInt(digits, 10, 64)
	if err != nil {
		return math.MaxInt64
	}
	return number
}

func allDigits(text string) bool {
	for index := 0; index < len(text); index++ {
		if text[index] < '0' || text[index] > '9' {
			return false
		}
	}
	return true
}

func ParseRange(header string, size int64) (Span, bool) {
	const prefix = "bytes="
	if len(header) < len(prefix)+1 || header[:len(prefix)] != prefix || size <= 0 {
		return Span{}, false
	}
	spec := header[len(prefix):]
	dash := -1
	for index := 0; index < len(spec); index++ {
		if spec[index] == '-' {
			if dash >= 0 {
				return Span{}, false
			}
			dash = index
		}
	}
	if dash < 0 {
		return Span{}, false
	}
	left, right := spec[:dash], spec[dash+1:]
	if !allDigits(left) || !allDigits(right) || (left == "" && right == "") {
		return Span{}, false
	}
	if left == "" {
		suffix := parseNumber(right)
		if suffix == 0 {
			return Span{}, false
		}
		return Span{First: max(size-suffix, 0), Last: size - 1}, true
	}
	first := parseNumber(left)
	last := size - 1
	if right != "" {
		last = min(parseNumber(right), size-1)
	}
	if first >= size || last < first {
		return Span{}, false
	}
	return Span{First: first, Last: last}, true
}
