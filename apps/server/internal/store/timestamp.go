package store

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

var ErrTimestamp = errors.New("invalid database timestamp")

func ParseTimestamp(text string) (time.Time, error) {
	date, clock, found := strings.Cut(text, " ")
	if !found || len(date) != 10 || date[4] != '-' || date[7] != '-' {
		return time.Time{}, ErrTimestamp
	}
	whole, fraction, _ := strings.Cut(clock, ".")
	if len(whole) != 8 || whole[2] != ':' || whole[5] != ':' {
		return time.Time{}, ErrTimestamp
	}
	numbers := []string{date[0:4], date[5:7], date[8:10], whole[0:2], whole[3:5], whole[6:8]}
	values := make([]int, len(numbers))
	for index, number := range numbers {
		value, err := strconv.Atoi(number)
		if err != nil || value < 0 || number[0] == '+' || number[0] == '-' {
			return time.Time{}, ErrTimestamp
		}
		values[index] = value
	}
	nanoseconds, err := parseFraction(fraction)
	if err != nil {
		return time.Time{}, err
	}
	moment := time.Date(values[0], time.Month(values[1]), values[2], values[3], values[4], values[5], nanoseconds, time.UTC)
	if moment.Year() != values[0] || int(moment.Month()) != values[1] || moment.Day() != values[2] || moment.Hour() != values[3] || moment.Minute() != values[4] || moment.Second() != values[5] {
		return time.Time{}, ErrTimestamp
	}
	return moment, nil
}

func parseFraction(fraction string) (int, error) {
	if fraction == "" {
		return 0, nil
	}
	if len(fraction) > 9 {
		return 0, ErrTimestamp
	}
	for _, character := range fraction {
		if character < '0' || character > '9' {
			return 0, ErrTimestamp
		}
	}
	padded := fraction + strings.Repeat("0", 9-len(fraction))
	return strconv.Atoi(padded)
}

func FormatISO8601Millis(moment time.Time) string {
	utc := moment.UTC()
	return fmt.Sprintf("%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", utc.Year(), int(utc.Month()), utc.Day(), utc.Hour(), utc.Minute(), utc.Second(), utc.Nanosecond()/1_000_000)
}
