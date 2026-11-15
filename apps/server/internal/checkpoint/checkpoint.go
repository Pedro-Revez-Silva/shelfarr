package checkpoint

import (
	"errors"
	"math"
	"math/big"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/strictjson"
)

const (
	MaxBodyBytes     = 64 << 10
	MaxVersion       = 1<<63 - 2
	maxSeconds       = 31 * 24 * 3600
	maxLocatorBytes  = 16 << 10
	maxHrefBytes     = 2048
	maxReadAlongMs   = 48 * 3_600_000
	maxPages         = 100_000
	maxTitleBytes    = 1024
	futureTolerance  = 5 * time.Minute
	earliestObserved = 1583
)

var (
	fixedLocatorKeys  = []string{"href", "type", "title", "locations", "text"}
	fixedLocationKeys = []string{"position", "progression", "totalProgression", "fragments"}

	ErrMalformed = errors.New("request body is not valid JSON")

	assetPattern    = regexp.MustCompile(`^[0-9a-f]{64}$`)
	mutationPattern = regexp.MustCompile(`(?i)^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$`)
	timestamp       = regexp.MustCompile(`^(\d{4})-(\d{2})-(\d{2})T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d{1,9})?(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)$`)
)

type Invalid struct{ Message string }

func (e Invalid) Error() string { return e.Message }

type Write struct {
	AssetID         string
	MutationID      string
	ExpectedVersion int64
	Resolve         bool
	ObservedAt      *time.Time
	Locator         *strictjson.Value
	LocatorText     *string
	PositionSeconds *float64
}

type Document struct{ root strictjson.Value }

func Decode(body []byte) (Document, error) {
	if len(body) > MaxBodyBytes {
		return Document{}, ErrMalformed
	}
	empty := Document{root: strictjson.Value{Kind: strictjson.Object}}
	if len(strings.TrimSpace(string(body))) == 0 {
		return empty, nil
	}
	parsed, err := strictjson.Parse(body)
	if err != nil {
		return Document{}, ErrMalformed
	}
	if parsed.Kind != strictjson.Object {
		return empty, nil
	}
	return Document{root: parsed}, nil
}

func (d Document) Status() (string, error) {
	value, present := d.root.Member("status")
	if !present || value.Kind != strictjson.String {
		return "", Invalid{"Choose unread, in_progress, or finished"}
	}
	switch value.Text {
	case "unread", "in_progress", "finished":
		return value.Text, nil
	}
	return "", Invalid{"Choose unread, in_progress, or finished"}
}

func (d Document) Progress(audiobook bool, now time.Time) (Write, error) {
	document := d.root
	var write Write
	if !required(document, &write) {
		return Write{}, Invalid{"An asset, expected version, and UUID mutation ID are required"}
	}
	resolve, _ := document.Member("resolve_conflict")
	switch {
	case resolve.Kind == strictjson.Bool:
		write.Resolve = resolve.Flag
	case resolve.Kind != strictjson.Null:
		return Write{}, Invalid{"resolve_conflict must be true or false"}
	}
	if observed, present := document.Member("observed_at"); present && observed.Kind != strictjson.Null {
		parsed, err := observedAt(observed, now)
		if err != nil {
			return Write{}, err
		}
		write.ObservedAt = &parsed
	}
	locator, _ := document.Member("locator")
	seconds, _ := document.Member("position_seconds")
	if audiobook {
		return write, audio(&write, locator, seconds)
	}
	return write, ebook(&write, locator, seconds)
}

func required(document strictjson.Value, write *Write) bool {
	asset, _ := document.Member("asset_id")
	version, _ := document.Member("expected_version")
	mutation, _ := document.Member("client_mutation_id")
	if asset.Kind != strictjson.String || !assetPattern.MatchString(asset.Text) ||
		mutation.Kind != strictjson.String || !mutationPattern.MatchString(mutation.Text) || version.Kind != strictjson.Integer {
		return false
	}
	number, ok := new(big.Int).SetString(version.Text, 10)
	if !ok || number.Sign() < 0 || number.Cmp(big.NewInt(MaxVersion)) > 0 {
		return false
	}
	write.AssetID, write.MutationID, write.ExpectedVersion = asset.Text, mutation.Text, number.Int64()
	return true
}

func audio(write *Write, locator, seconds strictjson.Value) error {
	invalid := Invalid{"A valid listening position is required"}
	if locator.Kind != strictjson.Null || seconds.Kind != strictjson.Integer && seconds.Kind != strictjson.Float {
		return invalid
	}
	parsed, err := strconv.ParseFloat(seconds.Text, 64)
	if err != nil || math.IsNaN(parsed) || math.IsInf(parsed, 0) || parsed < 0 || parsed > maxSeconds {
		return invalid
	}
	if parsed == 0 {
		parsed = 0
	}
	write.PositionSeconds = &parsed
	return nil
}

func ebook(write *Write, locator, seconds strictjson.Value) error {
	invalid := Invalid{"A bounded relative ebook locator is required"}
	if seconds.Kind != strictjson.Null || !validLocator(locator) {
		return invalid
	}
	text := locator.Encode()
	write.Locator, write.LocatorText = &locator, &text
	return nil
}

func observedAt(value strictjson.Value, now time.Time) (time.Time, error) {
	invalid := Invalid{"observed_at must be an ISO-8601 time with a time zone"}
	if value.Kind != strictjson.String {
		return time.Time{}, invalid
	}
	match := timestamp.FindStringSubmatch(value.Text)
	if match == nil {
		return time.Time{}, invalid
	}
	year, _ := strconv.Atoi(match[1])
	month, _ := strconv.Atoi(match[2])
	day, _ := strconv.Atoi(match[3])
	if year < earliestObserved || !realDate(year, month, day) {
		return time.Time{}, invalid
	}
	parsed, err := time.Parse(time.RFC3339Nano, value.Text)
	if err != nil {
		return time.Time{}, invalid
	}
	if parsed.After(now.Add(futureTolerance)) {
		return time.Time{}, Invalid{"observed_at is too far in the future; check this device's clock"}
	}
	utc := parsed.UTC().Truncate(time.Millisecond)
	if utc.Year() < earliestObserved || utc.Year() > 9999 {
		return time.Time{}, invalid
	}
	return utc, nil
}

func realDate(year, month, day int) bool {
	date := time.Date(year, time.Month(month), day, 0, 0, 0, 0, time.UTC)
	return date.Year() == year && int(date.Month()) == month && date.Day() == day
}

func validLocator(locator strictjson.Value) bool {
	if locator.Kind != strictjson.Object || len(locator.Encode()) > maxLocatorBytes || !finiteEverywhere(locator) {
		return false
	}
	href, present := locator.Member("href")
	if !present || href.Kind != strictjson.String || len(href.Text) > maxHrefBytes || blank(href.Text) || !relativePath(href.Text) {
		return false
	}
	locations, present := locator.Member("locations")
	if !present || locations.Kind != strictjson.Object {
		return false
	}
	for _, key := range []string{"progression", "totalProgression"} {
		if fraction, present := locations.Member(key); present && !unitInterval(fraction) {
			return false
		}
	}
	if position, present := locations.Member("position"); present && !positiveInteger(position) {
		return false
	}
	if readAlong, present := locations.Member("readAlong"); present && !validReadAlong(readAlong) {
		return false
	}
	return true
}

func finiteEverywhere(value strictjson.Value) bool {
	if !value.Finite() {
		return false
	}
	for _, item := range value.Items {
		if !finiteEverywhere(item) {
			return false
		}
	}
	for _, member := range value.Members {
		if !finiteEverywhere(member) {
			return false
		}
	}
	return true
}

func blank(text string) bool {
	return strings.TrimFunc(text, unicode.IsSpace) == ""
}

func relativePath(href string) bool {
	decoded, ok := unescape(href)
	if !ok || strings.HasPrefix(decoded, "/") || strings.ContainsAny(decoded, `:\`) {
		return false
	}
	for index := 0; index < len(decoded); index++ {
		if decoded[index] < 0x20 {
			return false
		}
	}
	for _, segment := range strings.Split(decoded, "/") {
		if segment == ".." {
			return false
		}
	}
	return true
}

func unescape(text string) (string, bool) {
	var builder strings.Builder
	for index := 0; index < len(text); index++ {
		if text[index] == '%' && index+2 < len(text) && hexDigit(text[index+1]) && hexDigit(text[index+2]) {
			value, _ := strconv.ParseUint(text[index+1:index+3], 16, 8)
			builder.WriteByte(byte(value))
			index += 2
			continue
		}
		builder.WriteByte(text[index])
	}
	result := builder.String()
	return result, utf8.ValidString(result)
}

func hexDigit(character byte) bool {
	return character >= '0' && character <= '9' || character >= 'a' && character <= 'f' || character >= 'A' && character <= 'F'
}

func unitInterval(value strictjson.Value) bool {
	if value.Kind != strictjson.Integer && value.Kind != strictjson.Float {
		return false
	}
	parsed, err := strconv.ParseFloat(value.Text, 64)
	return err == nil && parsed >= 0 && parsed <= 1
}

func positiveInteger(value strictjson.Value) bool {
	if value.Kind != strictjson.Integer {
		return false
	}
	number, ok := new(big.Int).SetString(value.Text, 10)
	return ok && number.Sign() > 0
}

func boundedInteger(value strictjson.Value, highest int64) bool {
	if value.Kind != strictjson.Integer {
		return false
	}
	number, ok := new(big.Int).SetString(value.Text, 10)
	return ok && number.Sign() >= 0 && number.Cmp(big.NewInt(highest)) <= 0
}

func validReadAlong(value strictjson.Value) bool {
	if value.Kind != strictjson.Object || len(value.Keys) != 3 {
		return false
	}
	generation, hasGeneration := value.Member("generation")
	audio, hasAudio := value.Member("audio")
	offset, hasOffset := value.Member("offset_ms")
	return hasGeneration && hasAudio && hasOffset && generation.Kind == strictjson.String && assetPattern.MatchString(generation.Text) &&
		boundedInteger(audio, 1999) && boundedInteger(offset, maxReadAlongMs)
}

type Place struct {
	Page      int64
	Href      string
	MediaType string
}

func FixedLayout(locator strictjson.Value, format string) (Place, error) {
	shape := Invalid{"A page place needs a one-based locations.position and no text position"}
	locations, _ := locator.Member("locations")
	position, _ := locations.Member("position")
	title, _ := locator.Member("title")
	text, _ := locator.Member("text")
	page, ok := pageNumber(position)
	if !ok || !withinKeys(locator, fixedLocatorKeys) || !withinKeys(locations, fixedLocationKeys) ||
		title.Kind != strictjson.Null && (title.Kind != strictjson.String || len(title.Text) > maxTitleBytes) ||
		text.Kind != strictjson.Null && text.Kind != strictjson.Object {
		return Place{}, shape
	}
	href, _ := locator.Member("href")
	kind, _ := locator.Member("type")
	fragments, hasFragments := locations.Member("fragments")
	if format == "pdf" {
		expected := "page=" + strconv.FormatInt(page, 10)
		singlePage := len(fragments.Items) == 1 && fragments.Kind == strictjson.Array && fragments.Items[0].Kind == strictjson.String && fragments.Items[0].Text == expected
		if href.Text != "document.pdf" || href.Kind != strictjson.String || kind.Text != "application/pdf" || kind.Kind != strictjson.String ||
			fragments.Kind != strictjson.Null && !singlePage {
			return Place{}, Invalid{"A PDF place is document.pdf with type application/pdf and an optional page=N fragment"}
		}
		return Place{Page: page, Href: href.Text, MediaType: kind.Text}, nil
	}
	if hasFragments {
		return Place{}, Invalid{"A comic place has no fragments"}
	}
	place := Place{Page: page, Href: href.Text}
	if kind.Kind == strictjson.String {
		place.MediaType = kind.Text
	}
	return place, nil
}

func pageNumber(value strictjson.Value) (int64, bool) {
	if value.Kind != strictjson.Integer {
		return 0, false
	}
	number, ok := new(big.Int).SetString(value.Text, 10)
	if !ok || number.Sign() < 1 || number.Cmp(big.NewInt(maxPages)) > 0 {
		return 0, false
	}
	return number.Int64(), true
}

func withinKeys(value strictjson.Value, allowed []string) bool {
	for _, key := range value.Keys {
		if !slices.Contains(allowed, key) {
			return false
		}
	}
	return true
}
