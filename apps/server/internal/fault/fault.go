//go:build !faultinject

package fault

import "context"

func Hit(ctx context.Context, name string) error {
	return nil
}

func Observe(err error) {}
