package gohttp

import (
	"sync"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/openlibrary"
)

const (
	offerLifetime      = 30 * time.Minute
	maxOffersPerPerson = 200
	maxOfferedAccounts = 128
)

type offeredWork struct {
	work    openlibrary.Work
	offered time.Time
}

type offeredWorks struct {
	mutex    sync.Mutex
	now      func() time.Time
	accounts map[int64]map[string]offeredWork
}

func newOfferedWorks(now func() time.Time) *offeredWorks {
	return &offeredWorks{now: now, accounts: map[int64]map[string]offeredWork{}}
}

func (o *offeredWorks) remember(accountID int64, works []openlibrary.Work) {
	o.mutex.Lock()
	defer o.mutex.Unlock()
	now := o.now()
	held := o.accounts[accountID]
	if held == nil {
		if len(o.accounts) >= maxOfferedAccounts {
			o.forgetOldestAccount()
		}
		held = map[string]offeredWork{}
		o.accounts[accountID] = held
	}
	for _, work := range works {
		held[work.ID] = offeredWork{work: work, offered: now}
	}
	for len(held) > maxOffersPerPerson {
		oldest := ""
		for id, entry := range held {
			if oldest == "" || entry.offered.Before(held[oldest].offered) {
				oldest = id
			}
		}
		delete(held, oldest)
	}
}

func (o *offeredWorks) forgetOldestAccount() {
	var oldestAccount int64
	var oldest time.Time
	for account, held := range o.accounts {
		for _, entry := range held {
			if oldest.IsZero() || entry.offered.Before(oldest) {
				oldest, oldestAccount = entry.offered, account
			}
		}
	}
	delete(o.accounts, oldestAccount)
}

func (o *offeredWorks) lookup(accountID int64, workID string) (openlibrary.Work, bool) {
	o.mutex.Lock()
	defer o.mutex.Unlock()
	entry, found := o.accounts[accountID][workID]
	if !found || o.now().Sub(entry.offered) > offerLifetime {
		return openlibrary.Work{}, false
	}
	return entry.work, true
}
