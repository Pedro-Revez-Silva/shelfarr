//go:build e2eclock

package main

import (
	"os"
	"strings"
	"time"
)

func testClock() func() time.Time {
	path := os.Getenv("SHELFARR_E2E_CLOCK_FILE")
	if path == "" {
		return nil
	}
	return func() time.Time {
		data, err := os.ReadFile(path)
		if err != nil {
			return time.Now()
		}
		moment, err := time.Parse(time.RFC3339Nano, strings.TrimSpace(string(data)))
		if err != nil {
			return time.Now()
		}
		return moment
	}
}
