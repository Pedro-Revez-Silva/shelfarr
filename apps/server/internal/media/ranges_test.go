package media

import "testing"

func TestRangesFollowTheRailsRules(t *testing.T) {
	const size = 100
	valid := map[string]Span{
		"bytes=0-0":                    {0, 0},
		"bytes=10-":                    {10, 99},
		"bytes=10-19":                  {10, 19},
		"bytes=-5":                     {95, 99},
		"bytes=-500":                   {0, 99},
		"bytes=90-9999999999999999999": {90, 99},
		"bytes=0-200":                  {0, 99},
		"bytes=99-99":                  {99, 99},
		"bytes=007-9":                  {7, 9},
	}
	for header, want := range valid {
		got, ok := ParseRange(header, size)
		if !ok || got != want {
			t.Errorf("%q: got %v %v, want %v", header, got, ok, want)
		}
	}
	invalid := []string{
		"", "bytes=", "bytes=-", "bytes=--1", "bytes=-0", "bytes=100-", "bytes=100-200", "bytes=9-3", "bytes=0-1,3-4",
		"BYTES=0-1", "bytes=a-b", "bytes=1-2x", "bytes= 1-2", "items=0-1", "bytes=-9999999999999999999999x", "bytes=9999999999999999999999-",
	}
	for _, header := range invalid {
		if got, ok := ParseRange(header, size); ok {
			t.Errorf("%q was accepted as %v", header, got)
		}
	}
	if _, ok := ParseRange("bytes=0-0", 0); ok {
		t.Error("a range of an empty file was accepted")
	}
	if got, ok := ParseRange("bytes=-9999999999999999999999", size); !ok || got != (Span{0, 99}) {
		t.Errorf("an oversized suffix: %v %v", got, ok)
	}
}

func TestContentDispositionMatchesRailsForAsciiAndUnicodeNames(t *testing.T) {
	cases := map[string]string{
		"plain.epub":          `inline; filename="plain.epub"; filename*=UTF-8''plain.epub`,
		"A Listening.mp3":     `inline; filename="A Listening.mp3"; filename*=UTF-8''A%20Listening.mp3`,
		"Café Ébène 日本語.epub": `inline; filename="Cafe Ebene %3F%3F%3F.epub"; filename*=UTF-8''Caf%C3%A9%20%C3%89b%C3%A8ne%20%E6%97%A5%E6%9C%AC%E8%AA%9E.epub`,
		`a"b;c.epub`:          `inline; filename="a%22b%3Bc.epub"; filename*=UTF-8''a%22b%3Bc.epub`,
		"a&b.epub":            `inline; filename="a%26b.epub"; filename*=UTF-8''a&b.epub`,
	}
	for name, want := range cases {
		if got := ContentDisposition("inline", name); got != want {
			t.Errorf("%q:\n got %s\nwant %s", name, got, want)
		}
	}
}
