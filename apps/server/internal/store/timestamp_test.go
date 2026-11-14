package store

import "testing"

func TestParseAndFormatTimestamp(t *testing.T) {
	cases := []struct{ stored, want string }{
		{"2026-11-13 08:30:15.123987", "2026-11-13T08:30:15.123Z"},
		{"2026-11-13 08:30:15", "2026-11-13T08:30:15.000Z"},
		{"2026-11-13 08:29:59.999500", "2026-11-13T08:29:59.999Z"},
		{"1969-12-31 23:59:59.999500", "1969-12-31T23:59:59.999Z"},
		{"1969-12-31 23:59:59.250000", "1969-12-31T23:59:59.250Z"},
		{"2026-02-28 00:00:00.000001", "2026-02-28T00:00:00.000Z"},
		{"2028-02-29 12:00:00.5", "2028-02-29T12:00:00.500Z"},
	}
	for _, testCase := range cases {
		parsed, err := ParseTimestamp(testCase.stored)
		if err != nil {
			t.Errorf("%q: %v", testCase.stored, err)
			continue
		}
		if got := FormatISO8601Millis(parsed); got != testCase.want {
			t.Errorf("%q = %q, want %q", testCase.stored, got, testCase.want)
		}
	}
}

func TestParseTimestampRejects(t *testing.T) {
	for _, stored := range []string{
		"", "2026-11-13", "2026-11-13T08:30:15", "2026-13-01 00:00:00", "2026-02-30 00:00:00", "2026-11-13 25:00:00",
		"2026-11-13 08:30:15.1234567890", "2026-11-13 08:30:15.12a", "2026-11-13 8:30:15", "+026-11-13 08:30:15", "2026-11-13 08:30:15 ",
	} {
		if _, err := ParseTimestamp(stored); err == nil {
			t.Errorf("%q accepted", stored)
		}
	}
}
