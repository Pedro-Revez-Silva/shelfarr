package library

import (
	"math/big"
	"regexp"
	"sort"
	"strings"
)

var digitRun = regexp.MustCompile(`[0-9]+`)

type naturalPart struct {
	text   string
	number *big.Int
}

func naturalKey(path string) []naturalPart {
	lowered := strings.ToLower(path)
	var parts []naturalPart
	last := 0
	for _, bounds := range digitRun.FindAllStringIndex(lowered, -1) {
		parts = append(parts, naturalPart{text: lowered[last:bounds[0]]})
		number, _ := new(big.Int).SetString(lowered[bounds[0]:bounds[1]], 10)
		parts = append(parts, naturalPart{number: number})
		last = bounds[1]
	}
	if last < len(lowered) {
		parts = append(parts, naturalPart{text: lowered[last:]})
	}
	return parts
}

func compareKeys(left, right []naturalPart) int {
	for index := 0; index < len(left) && index < len(right); index++ {
		var order int
		if left[index].number != nil && right[index].number != nil {
			order = left[index].number.Cmp(right[index].number)
		} else {
			order = strings.Compare(left[index].text, right[index].text)
		}
		if order != 0 {
			return order
		}
	}
	return len(left) - len(right)
}

func sortNatural(paths []string) {
	keys := make(map[string][]naturalPart, len(paths))
	for _, path := range paths {
		keys[path] = naturalKey(path)
	}
	sort.SliceStable(paths, func(i, j int) bool { return compareKeys(keys[paths[i]], keys[paths[j]]) < 0 })
}
