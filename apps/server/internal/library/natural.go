package library

import (
	"sort"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/naturalorder"
)

func sortNatural(paths []string) {
	keys := make(map[string]naturalorder.Key, len(paths))
	for _, path := range paths {
		keys[path] = naturalorder.KeyOf(path)
	}
	sort.SliceStable(paths, func(i, j int) bool { return naturalorder.Compare(keys[paths[i]], keys[paths[j]]) < 0 })
}
