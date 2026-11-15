package loginlimit

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"hash/fnv"
	"sync"
	"time"
)

const buckets = 1024

type Limiter struct {
	mutex  sync.Mutex
	salt   [8]byte
	limit  int
	window time.Duration
	slots  [buckets]struct {
		start time.Time
		count int
	}
	workers chan struct{}
}

func New(limit int, window time.Duration, workers int) *Limiter {
	limiter := &Limiter{limit: limit, window: window, workers: make(chan struct{}, workers)}
	rand.Read(limiter.salt[:])
	return limiter
}

func (l *Limiter) bucket(key string) int {
	hash := fnv.New64a()
	hash.Write(l.salt[:])
	hash.Write([]byte(key))
	return int(binary.BigEndian.Uint64(hash.Sum(nil)) % buckets)
}

func (l *Limiter) Allow(key string, now time.Time) (bool, time.Duration) {
	l.mutex.Lock()
	defer l.mutex.Unlock()
	slot := &l.slots[l.bucket(key)]
	if slot.start.IsZero() || !now.Before(slot.start.Add(l.window)) {
		slot.start, slot.count = now, 0
	}
	if slot.count >= l.limit {
		return false, slot.start.Add(l.window).Sub(now)
	}
	slot.count++
	return true, 0
}

func (l *Limiter) Acquire(ctx context.Context, wait time.Duration) bool {
	timer := time.NewTimer(wait)
	defer timer.Stop()
	select {
	case l.workers <- struct{}{}:
		return true
	case <-timer.C:
		return false
	case <-ctx.Done():
		return false
	}
}

func (l *Limiter) Release() { <-l.workers }
