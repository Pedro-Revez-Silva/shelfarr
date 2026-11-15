package wfstore

import "time"

const railsTimestamp = "2006-01-02 15:04:05.000000"

func FormatTimestamp(moment time.Time) string {
	return moment.UTC().Format(railsTimestamp)
}

func ParseTimestamp(text string) (time.Time, error) {
	return time.ParseInLocation("2006-01-02 15:04:05.999999999", text, time.UTC)
}
