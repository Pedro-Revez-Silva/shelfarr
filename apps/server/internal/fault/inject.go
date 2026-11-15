//go:build faultinject

package fault

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

var ErrInjected = errors.New("injected fault")

var (
	directory = os.Getenv("SHELFARR_FAULT_DIR")
	actions   = parse(os.Getenv("SHELFARR_FAULT_POINTS"))
)

func parse(spec string) map[string]string {
	parsed := map[string]string{}
	for _, entry := range strings.Split(spec, ",") {
		name, action, found := strings.Cut(strings.TrimSpace(entry), "=")
		if found {
			parsed[name] = action
		}
	}
	return parsed
}

func Hit(ctx context.Context, name string) error {
	switch actions[name] {
	case "kill":
		syscall.Kill(os.Getpid(), syscall.SIGKILL)
		select {}
	case "panic":
		panic("injected fault " + name)
	case "error":
		return ErrInjected
	case "park":
		return park(ctx, name)
	}
	return nil
}

func park(ctx context.Context, name string) error {
	if err := os.WriteFile(filepath.Join(directory, name+".reached"), nil, 0o600); err != nil {
		return err
	}
	release := filepath.Join(directory, name+".release")
	for {
		if _, err := os.Stat(release); err == nil {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(2 * time.Millisecond):
		}
	}
}

func Observe(err error) {
	for current := err; current != nil; current = errors.Unwrap(current) {
		os.Stderr.WriteString("fault-build diagnostic: " + current.Error() + "\n")
	}
}
