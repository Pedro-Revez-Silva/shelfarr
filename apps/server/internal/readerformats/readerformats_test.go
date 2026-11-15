package readerformats

import (
	"errors"
	"strings"
	"testing"
)

func TestAbsentHeaderKeepsTheLegacyEpubContract(t *testing.T) {
	formats, err := ParseFormats("", false)
	if err != nil || formats.Declared || !formats.Default() || formats.Graphic() || formats.Joined() != "epub" {
		t.Fatalf("%+v %v", formats, err)
	}
}

func TestDeclaredFormatsAreNormalisedLikeRails(t *testing.T) {
	cases := map[string]string{"epub": "epub", "epub,epub": "epub", " epub , pdf": "epub,pdf", "pdf,cbz,epub": "cbz,epub,pdf"}
	for header, want := range cases {
		formats, err := ParseFormats(header, true)
		if err != nil || formats.Joined() != want || !formats.Declared {
			t.Fatalf("%q: %+v %v", header, formats, err)
		}
	}
}

func TestFormatsRefuseMalformedDeclarationsWithTheRailsMessages(t *testing.T) {
	for _, header := range []string{"", strings.Repeat("e", 65), "epub,", ",epub", "EPUB", "epub;q=1", "mobi"} {
		_, err := ParseFormats(header, true)
		var invalid Invalid
		if !errors.As(err, &invalid) || invalid.Message == "" {
			t.Fatalf("%q was accepted", header)
		}
	}
	_, err := ParseFormats("", true)
	if err.Error() != "Declare reader formats as a comma-separated list such as epub,pdf,cbz" {
		t.Fatalf("message: %v", err)
	}
	_, err = ParseFormats("mobi", true)
	if err.Error() != "Unknown or empty reader format; supported formats are cbz,epub,pdf" {
		t.Fatalf("message: %v", err)
	}
}

func TestFixedLayoutFormatsAreRefusedNotIgnored(t *testing.T) {
	for _, header := range []string{"pdf", "epub,cbz", "cbz,pdf,epub"} {
		formats, err := ParseFormats(header, true)
		if err != nil || !errors.Is(formats.RequireSupported(), ErrUnsupported) {
			t.Fatalf("%q: %v", header, err)
		}
	}
	formats, _ := ParseFormats("epub", true)
	if formats.RequireSupported() != nil {
		t.Fatal("epub alone must be supported")
	}
}

func TestFeaturesIgnoreUnknownNamesButRefuseMalformedOnes(t *testing.T) {
	if readAlong, err := ParseFeatures("read-along", true); err != nil || !readAlong {
		t.Fatalf("%v %v", readAlong, err)
	}
	if readAlong, err := ParseFeatures("future-thing", true); err != nil || readAlong {
		t.Fatalf("%v %v", readAlong, err)
	}
	if readAlong, err := ParseFeatures("", false); err != nil || readAlong {
		t.Fatalf("%v %v", readAlong, err)
	}
	for _, header := range []string{"", "Read-Along", "read along", "1abc", "read-along,", strings.Repeat("a", 129)} {
		if _, err := ParseFeatures(header, true); err == nil {
			t.Fatalf("%q was accepted", header)
		}
	}
}
