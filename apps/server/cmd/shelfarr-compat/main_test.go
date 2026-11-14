package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRunRefusesBadUsage(t *testing.T) {
	cases := [][]string{
		nil,
		{"serve"},
		{"compat-check"},
		{"compat-check", "--bundle", ""},
		{"compat-check", "--bundle", "x", "--timeout", "0s"},
		{"compat-check", "--bundle", "x", "--timeout", "11m"},
		{"compat-check", "--bundle", "x", "--unknown"},
	}
	for _, arguments := range cases {
		var stdout, stderr bytes.Buffer
		if code := run(arguments, &stdout, &stderr); code != exitRefused || stdout.Len() != 0 {
			t.Errorf("%v: code %d, stdout %q", arguments, code, stdout.String())
		}
	}
}

func TestRunNeverPrintsTheBundlePath(t *testing.T) {
	secretDirectory := filepath.Join(t.TempDir(), "private-location")
	if err := os.Mkdir(secretDirectory, 0o700); err != nil {
		t.Fatal(err)
	}
	for _, target := range []string{secretDirectory, filepath.Join(secretDirectory, "absent")} {
		var stdout, stderr bytes.Buffer
		code := run([]string{"compat-check", "--bundle", target}, &stdout, &stderr)
		if code != exitRefused {
			t.Fatalf("code = %d", code)
		}
		if strings.Contains(stdout.String()+stderr.String(), "private-location") {
			t.Fatalf("output leaks the path: %q", stderr.String())
		}
	}
}
