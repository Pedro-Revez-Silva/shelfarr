package loginlimit

import (
	"context"
	"testing"
	"time"
)

func TestAWindowAllowsTheLimitThenRefusesUntilItEnds(t *testing.T) {
	limiter := New(3, time.Minute, 2)
	start := time.Date(2026, 11, 15, 12, 0, 0, 0, time.UTC)
	for attempt := 0; attempt < 3; attempt++ {
		if allowed, _ := limiter.Allow("203.0.113.9", start.Add(time.Duration(attempt)*time.Second)); !allowed {
			t.Fatalf("attempt %d refused", attempt)
		}
	}
	allowed, wait := limiter.Allow("203.0.113.9", start.Add(10*time.Second))
	if allowed || wait != 50*time.Second {
		t.Fatalf("allowed=%t wait=%v", allowed, wait)
	}
	if allowed, _ := limiter.Allow("203.0.113.9", start.Add(time.Minute)); !allowed {
		t.Fatal("the window did not reopen")
	}
}

func TestEveryAddressHasItsOwnBudgetUnlessBucketsCollide(t *testing.T) {
	limiter := New(1, time.Hour, 1)
	now := time.Now()
	allowed := 0
	for index := 0; index < 200; index++ {
		if ok, _ := limiter.Allow(string(rune('a'+index%26))+string(rune('A'+index/26)), now); ok {
			allowed++
		}
	}
	if allowed < 150 || allowed > 200 {
		t.Fatalf("%d of 200 addresses were allowed once", allowed)
	}
}

func TestWorkersAreBoundedAndReleased(t *testing.T) {
	limiter := New(1, time.Minute, 2)
	ctx := context.Background()
	if !limiter.Acquire(ctx, time.Second) || !limiter.Acquire(ctx, time.Second) {
		t.Fatal("two slots were not granted")
	}
	if limiter.Acquire(ctx, 20*time.Millisecond) {
		t.Fatal("a third slot was granted")
	}
	limiter.Release()
	if !limiter.Acquire(ctx, time.Second) {
		t.Fatal("a released slot was not reusable")
	}
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if limiter.Acquire(cancelled, time.Second) {
		t.Fatal("a cancelled caller got a slot")
	}
}
