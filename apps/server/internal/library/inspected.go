package library

import "sync"

const inspectedLimit = 512

type inspectedPages struct {
	lock   sync.Mutex
	counts map[string]int
	order  []string
}

var inspected = &inspectedPages{counts: map[string]int{}}

func (c *inspectedPages) get(id string) (int, bool) {
	c.lock.Lock()
	defer c.lock.Unlock()
	count, hit := c.counts[id]
	return count, hit
}

func (c *inspectedPages) remember(id string, count int) {
	c.lock.Lock()
	defer c.lock.Unlock()
	if _, present := c.counts[id]; present {
		c.forget(id)
	}
	c.counts[id] = count
	c.order = append(c.order, id)
	for len(c.order) > inspectedLimit {
		delete(c.counts, c.order[0])
		c.order = c.order[1:]
	}
}

func (c *inspectedPages) forget(id string) {
	for index, held := range c.order {
		if held == id {
			c.order = append(c.order[:index], c.order[index+1:]...)
			return
		}
	}
}
