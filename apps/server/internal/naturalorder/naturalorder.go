package naturalorder

import (
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"

	"golang.org/x/text/cases"
	"golang.org/x/text/language"
)

var digitRun = regexp.MustCompile(`[0-9]+`)

type part struct {
	text   string
	digits string
	number bool
}

type Key []part

var unlowered = &unicode.RangeTable{R32: []unicode.Range32{
	{Lo: 0x1c89, Hi: 0x1c89, Stride: 1}, {Lo: 0xa7cb, Hi: 0xa7cc, Stride: 1}, {Lo: 0xa7ce, Hi: 0xa7ce, Stride: 1}, {Lo: 0xa7d2, Hi: 0xa7d2, Stride: 1},
	{Lo: 0xa7d4, Hi: 0xa7d4, Stride: 1}, {Lo: 0xa7da, Hi: 0xa7da, Stride: 1}, {Lo: 0xa7dc, Hi: 0xa7dc, Stride: 1},
	{Lo: 0x10d50, Hi: 0x10d65, Stride: 1}, {Lo: 0x16ea0, Hi: 0x16eb8, Stride: 1},
}}

func Downcase(text string) string {
	var lowered strings.Builder
	start := 0
	for index, character := range text {
		if !unicode.Is(unlowered, character) {
			continue
		}
		lowered.WriteString(lower(text[start:index]))
		lowered.WriteRune(character)
		start = index + utf8.RuneLen(character)
	}
	lowered.WriteString(lower(text[start:]))
	return lowered.String()
}

func lower(text string) string {
	return cases.Lower(language.Und, cases.HandleFinalSigma(false)).String(text)
}

func KeyOf(name string) Key {
	lowered := Downcase(name)
	var parts Key
	last := 0
	for _, bounds := range digitRun.FindAllStringIndex(lowered, -1) {
		parts = append(parts, part{text: lowered[last:bounds[0]]})
		parts = append(parts, part{digits: strings.TrimLeft(lowered[bounds[0]:bounds[1]], "0"), number: true})
		last = bounds[1]
	}
	if last < len(lowered) {
		parts = append(parts, part{text: lowered[last:]})
	}
	return parts
}

func compareDigits(left, right string) int {
	if len(left) != len(right) {
		return len(left) - len(right)
	}
	return strings.Compare(left, right)
}

func Compare(left, right Key) int {
	for index := 0; index < len(left) && index < len(right); index++ {
		var order int
		if left[index].number && right[index].number {
			order = compareDigits(left[index].digits, right[index].digits)
		} else {
			order = strings.Compare(left[index].text, right[index].text)
		}
		if order != 0 {
			return order
		}
	}
	return len(left) - len(right)
}
