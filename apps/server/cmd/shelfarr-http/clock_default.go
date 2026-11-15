//go:build !e2eclock

package main

import "time"

func testClock() func() time.Time { return nil }
