package naturalorder

import (
	"slices"
	"sort"
	"testing"
)

func TestDowncaseMatchesRubyThreeThree(t *testing.T) {
	cases := map[string]string{
		"ΑΣ":            "ασ",
		"Α.Σ":           "α.σ",
		"ΑΣ ΑΣ":         "ασ ασ",
		"İ2":            "i̇2",
		"ǅ":             "ǆ",
		"ẞ":             "ß",
		"ÉCLAIR":        "éclair",
		"Ᲊ":             "Ᲊ",
		"Ꟍ1":            "Ꟍ1",
		"\U00010d50x":   "\U00010d50x",
		"\U00016ea0Α":   "\U00016ea0α",
		"Mixed 10 CASE": "mixed 10 case",
	}
	for input, want := range cases {
		if got := Downcase(input); got != want {
			t.Errorf("Downcase(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestKeysCompareNumbersNumericallyAndTextBytewise(t *testing.T) {
	names := []string{"page 10.png", "Page 2.png", "page 001.png", "Page 1.jpg", "p99999999999999999999.png", "p100000000000000000000.png", "a.png", "1a.png", "ch10/a.png", "CH2/a.png"}
	sort.SliceStable(names, func(i, j int) bool { return Compare(KeyOf(names[i]), KeyOf(names[j])) < 0 })
	want := []string{"1a.png", "a.png", "CH2/a.png", "ch10/a.png", "p99999999999999999999.png", "p100000000000000000000.png", "Page 1.jpg", "page 001.png", "Page 2.png", "page 10.png"}
	sorted := slices.Clone(names)
	if !slices.Equal(sorted, want) {
		t.Fatalf("order = %v", sorted)
	}
}

func TestLeadingDigitsProduceAnEmptyFirstTextPart(t *testing.T) {
	if Compare(KeyOf("1a"), KeyOf("a")) >= 0 || Compare(KeyOf("a"), KeyOf("a")) != 0 || Compare(KeyOf("a1"), KeyOf("a")) <= 0 {
		t.Fatal("digit runs do not sort as Ruby's split(/(\\d+)/) does")
	}
}
