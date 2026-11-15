package checkpoint

import (
	"errors"
	"fmt"
	"math"
	"strings"
	"testing"
	"time"
)

var (
	clock    = time.Date(2026, 11, 14, 12, 0, 0, 0, time.UTC)
	asset    = strings.Repeat("a", 64)
	mutation = "6f1c8d2e-3b4a-4c5d-8e9f-0a1b2c3d4e5f"
)

func body(fields string) []byte {
	return []byte(fmt.Sprintf(`{"asset_id":"%s","expected_version":0,"client_mutation_id":"%s"%s}`, asset, mutation, fields))
}

func progress(t *testing.T, raw []byte, audiobook bool) (Write, error) {
	t.Helper()
	document, err := Decode(raw)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	return document.Progress(audiobook, clock)
}

func message(err error) string {
	var invalid Invalid
	if errors.As(err, &invalid) {
		return invalid.Message
	}
	if err == nil {
		return ""
	}
	return "unexpected: " + err.Error()
}

const (
	requiredMessage = "An asset, expected version, and UUID mutation ID are required"
	listenMessage   = "A valid listening position is required"
	locatorMessage  = "A bounded relative ebook locator is required"
	timeMessage     = "observed_at must be an ISO-8601 time with a time zone"
	futureMessage   = "observed_at is too far in the future; check this device's clock"
	resolveMessage  = "resolve_conflict must be true or false"
)

func TestRequiredFieldsFollowTheRailsWriter(t *testing.T) {
	cases := map[string]string{
		`{}`: requiredMessage, `[]`: requiredMessage, `null`: requiredMessage, `"x"`: requiredMessage, `5`: requiredMessage, ``: requiredMessage, `  `: requiredMessage,
		fmt.Sprintf(`{"asset_id":"%s","expected_version":"0","client_mutation_id":"%s","position_seconds":1}`, asset, mutation):                  requiredMessage,
		fmt.Sprintf(`{"asset_id":"%s","expected_version":0.0,"client_mutation_id":"%s","position_seconds":1}`, asset, mutation):                  requiredMessage,
		fmt.Sprintf(`{"asset_id":"%s","expected_version":0e0,"client_mutation_id":"%s","position_seconds":1}`, asset, mutation):                  requiredMessage,
		fmt.Sprintf(`{"asset_id":"%s","expected_version":null,"client_mutation_id":"%s","position_seconds":1}`, asset, mutation):                 requiredMessage,
		fmt.Sprintf(`{"asset_id":"%s","expected_version":true,"client_mutation_id":"%s","position_seconds":1}`, asset, mutation):                 requiredMessage,
		fmt.Sprintf(`{"asset_id":"%s","expected_version":-1,"client_mutation_id":"%s","position_seconds":1}`, asset, mutation):                   requiredMessage,
		fmt.Sprintf(`{"asset_id":"%s","expected_version":9223372036854775807,"client_mutation_id":"%s","position_seconds":1}`, asset, mutation):  requiredMessage,
		fmt.Sprintf(`{"asset_id":"%s","expected_version":92233720368547758080,"client_mutation_id":"%s","position_seconds":1}`, asset, mutation): requiredMessage,
		fmt.Sprintf(`{"asset_id":"%s","expected_version":[0],"client_mutation_id":"%s","position_seconds":1}`, asset, mutation):                  requiredMessage,
		fmt.Sprintf(`{"asset_id":"%s","expected_version":0,"client_mutation_id":"not-a-uuid","position_seconds":1}`, asset):                      requiredMessage,
		fmt.Sprintf(`{"asset_id":"%s","expected_version":0,"client_mutation_id":"%s ","position_seconds":1}`, asset, mutation):                   requiredMessage,
		fmt.Sprintf(`{"asset_id":"%s","expected_version":0,"client_mutation_id":null,"position_seconds":1}`, asset):                              requiredMessage,
		fmt.Sprintf(`{"asset_id":"%s","expected_version":0,"position_seconds":1}`, mutation):                                                     requiredMessage,
		fmt.Sprintf(`{"asset_id":"%s","expected_version":0,"client_mutation_id":"%s","position_seconds":1}`, strings.ToUpper(asset), mutation):   requiredMessage,
		fmt.Sprintf(`{"asset_id":"%s","expected_version":0,"client_mutation_id":"%s","position_seconds":1}`, asset[:63], mutation):               requiredMessage,
		fmt.Sprintf(`{"asset_id":["%s"],"expected_version":0,"client_mutation_id":"%s","position_seconds":1}`, asset, mutation):                  requiredMessage,
	}
	for raw, want := range cases {
		if _, err := progress(t, []byte(raw), true); message(err) != want {
			t.Errorf("%s: got %q", raw, message(err))
		}
	}
}

func TestExpectedVersionRangeIsExactToTheLastValue(t *testing.T) {
	for raw, want := range map[string]int64{"0": 0, "-0": 0, "7": 7, "9007199254740993": 9007199254740993, "9223372036854775806": 9223372036854775806} {
		write, err := progress(t, []byte(fmt.Sprintf(`{"asset_id":"%s","expected_version":%s,"client_mutation_id":"%s","position_seconds":1}`, asset, raw, mutation)), true)
		if err != nil || write.ExpectedVersion != want {
			t.Errorf("%s: %v %v", raw, write.ExpectedVersion, err)
		}
	}
}

func TestUUIDsAreAcceptedInEitherCaseAndKeptAsSent(t *testing.T) {
	upper := strings.ToUpper(mutation)
	write, err := progress(t, []byte(fmt.Sprintf(`{"asset_id":"%s","expected_version":0,"client_mutation_id":"%s","position_seconds":1}`, asset, upper)), true)
	if err != nil || write.MutationID != upper {
		t.Fatalf("%q %v", write.MutationID, err)
	}
}

func TestListeningPositionsFollowTheRailsBounds(t *testing.T) {
	valid := map[string]float64{"0": 0, "-0": 0, "-0.0": 0, "17.5": 17.5, "10": 10, "2678400": 2678400, "2678400.0": 2678400, "1e2": 100, "0.000001": 0.000001}
	for raw, want := range valid {
		write, err := progress(t, body(`,"position_seconds":`+raw), true)
		if err != nil || write.PositionSeconds == nil || *write.PositionSeconds != want || math.Signbit(*write.PositionSeconds) {
			t.Errorf("%s: %v %v", raw, write.PositionSeconds, err)
		}
		if write.Locator != nil || write.LocatorText != nil {
			t.Errorf("%s: a listening position kept a locator", raw)
		}
	}
	for _, raw := range []string{`-1`, `-0.001`, `2678400.001`, `2678401`, `999999999`, `"10"`, `null`, `true`, `[1]`, `{"a":1}`, `1e400`, `-1e400`, `99999999999999999999999999`} {
		if _, err := progress(t, body(`,"position_seconds":`+raw), true); message(err) != listenMessage {
			t.Errorf("%s: %q", raw, message(err))
		}
	}
	if _, err := progress(t, body(``), true); message(err) != listenMessage {
		t.Error("a missing position was accepted")
	}
	for _, locator := range []string{`{}`, `{"href":"a.xhtml","locations":{}}`, `[]`, `"x"`, `5`, `false`} {
		if _, err := progress(t, body(`,"position_seconds":3,"locator":`+locator), true); message(err) != listenMessage {
			t.Errorf("locator %s next to a listening position: %q", locator, message(err))
		}
	}
	if _, err := progress(t, body(`,"position_seconds":3,"locator":null`), true); err != nil {
		t.Errorf("an explicit null locator: %v", err)
	}
}

func locatorBody(locator string) []byte { return body(`,"locator":` + locator) }

func TestEbookLocatorsKeepTheirFullAcceptedShape(t *testing.T) {
	full := `{"href":"OEBPS/chapter%201.xhtml#frag","type":"application/xhtml+xml","title":"A","locations":{"progression":0.3,"totalProgression":1,"position":4,"readAlong":{"generation":"` + asset + `","audio":1999,"offset_ms":172800000},"cfi":"/2/4[x]!/4","extra":[1,{"deep":null}]},"text":{"highlight":"é"},"vendor":{"k":[]}}`
	write, err := progress(t, locatorBody(full), false)
	if err != nil || write.LocatorText == nil || *write.LocatorText != full {
		t.Fatalf("%v %v", write.LocatorText, err)
	}
	if write.PositionSeconds != nil {
		t.Fatal("an ebook position carried seconds")
	}
	for _, accepted := range []string{
		`{"href":"a","locations":{}}`, `{"href":"a..b","locations":{}}`, `{"href":"%252e%252e/x","locations":{}}`,
		`{"href":"a b","locations":{"totalProgression":1.0,"progression":1e0}}`, `{"href":"a","locations":{"position":99999999999999999999}}`, `{"href":"a","locations":{"position":1}}`,
		`{"href":"a?x=1#y","locations":{}}`, `{"href":"` + strings.Repeat("a", 2048) + `","locations":{}}`, `{"href":"a","locations":{"readAlong":{"generation":"` + asset + `","audio":0,"offset_ms":0}}}`,
	} {
		if _, err := progress(t, locatorBody(accepted), false); err != nil {
			t.Errorf("%s: %q", accepted, message(err))
		}
	}
}

func TestEbookLocatorsRefuseWhatRailsRefuses(t *testing.T) {
	long := strings.Repeat("a", 2049)
	refused := []string{
		`null`, `[]`, `"x"`, `5`, `true`, `{}`, `{"locations":{}}`, `{"href":"a"}`, `{"href":"a","locations":null}`, `{"href":"a","locations":[]}`, `{"href":"","locations":{}}`, `{"href":" \t\u00a0\u3000","locations":{}}`,
		`{"href":null,"locations":{}}`, `{"href":5,"locations":{}}`, `{"href":"` + long + `","locations":{}}`, `{"href":"/abs","locations":{}}`, `{"href":"%2Fabs","locations":{}}`,
		`{"href":"https://attacker.example","locations":{}}`, `{"href":"a:b","locations":{}}`, `{"href":"a%3Ab","locations":{}}`, `{"href":"..","locations":{}}`, `{"href":"../private.xhtml","locations":{}}`, `{"href":"a/../b/..","locations":{}}`,
		`{"href":"%2e%2e/x","locations":{}}`, `{"href":"a/%2E%2E","locations":{}}`, `{"href":"a\\b","locations":{}}`, `{"href":"a%5Cb","locations":{}}`, `{"href":"a%00b","locations":{}}`, `{"href":"a\u0001b","locations":{}}`, `{"href":"a%1fb","locations":{}}`,
		`{"href":"a%ffb","locations":{}}`, `{"href":"a%c3","locations":{}}`,
		`{"href":"a","locations":{"progression":1.1}}`, `{"href":"a","locations":{"progression":-0.1}}`, `{"href":"a","locations":{"progression":null}}`, `{"href":"a","locations":{"progression":"0.5"}}`, `{"href":"a","locations":{"totalProgression":2}}`,
		`{"href":"a","locations":{"progression":1e400}}`, `{"href":"a","locations":{"position":0}}`, `{"href":"a","locations":{"position":-1}}`, `{"href":"a","locations":{"position":1.0}}`, `{"href":"a","locations":{"position":null}}`, `{"href":"a","locations":{"position":"3"}}`,
		`{"href":"a","locations":{"readAlong":null}}`, `{"href":"a","locations":{"readAlong":[]}}`, `{"href":"a","locations":{"readAlong":{}}}`,
		`{"href":"a","locations":{"readAlong":{"generation":"` + asset + `","audio":0}}}`, `{"href":"a","locations":{"readAlong":{"generation":"` + asset + `","audio":0,"offset_ms":0,"extra":1}}}`,
		`{"href":"a","locations":{"readAlong":{"generation":"` + strings.ToUpper(asset) + `","audio":0,"offset_ms":0}}}`, `{"href":"a","locations":{"readAlong":{"generation":"` + asset + `","audio":2000,"offset_ms":0}}}`,
		`{"href":"a","locations":{"readAlong":{"generation":"` + asset + `","audio":-1,"offset_ms":0}}}`, `{"href":"a","locations":{"readAlong":{"generation":"` + asset + `","audio":0,"offset_ms":172800001}}}`,
		`{"href":"a","locations":{"readAlong":{"generation":"` + asset + `","audio":0.0,"offset_ms":0}}}`,
		`{"href":"a","locations":{},"text":{"highlight":"` + strings.Repeat("x", 17_000) + `"}}`, `{"href":"a","locations":{},"vendor":1e400}`, `{"href":"a","locations":{},"vendor":[1,{"n":-1e999}]}`,
	}
	for _, locator := range refused {
		if _, err := progress(t, locatorBody(locator), false); message(err) != locatorMessage {
			t.Errorf("%.80s: %q", locator, message(err))
		}
	}
	if _, err := progress(t, body(`,"locator":{"href":"a","locations":{}},"position_seconds":0`), false); message(err) != locatorMessage {
		t.Error("an ebook checkpoint with a listening position was accepted")
	}
	for _, seconds := range []string{`[1]`, `{"a":1}`, `"1"`, `false`} {
		if _, err := progress(t, body(`,"locator":{"href":"a","locations":{}},"position_seconds":`+seconds), false); message(err) != locatorMessage {
			t.Errorf("position_seconds %s next to an ebook locator: %q", seconds, message(err))
		}
	}
	if _, err := progress(t, body(`,"locator":{"href":"a","locations":{}},"position_seconds":null`), false); err != nil {
		t.Errorf("an explicit null position: %v", err)
	}
}

func TestObservedAtIsAnExplicitZoneISO8601TimeNormalisedToUTCMilliseconds(t *testing.T) {
	accepted := map[string]time.Time{
		"2025-11-07T10:15:30.123456+01:00": time.Date(2025, 11, 7, 9, 15, 30, 123_000_000, time.UTC),
		"2025-11-07T10:15:30Z":             time.Date(2025, 11, 7, 10, 15, 30, 0, time.UTC),
		"2025-11-07T10:15:30.1Z":           time.Date(2025, 11, 7, 10, 15, 30, 100_000_000, time.UTC),
		"2025-11-07T10:15:30.999999999Z":   time.Date(2025, 11, 7, 10, 15, 30, 999_000_000, time.UTC),
		"2024-02-29T23:59:59-05:30":        time.Date(2024, 3, 1, 5, 29, 59, 0, time.UTC),
		"2026-11-14T12:04:59.999Z":         time.Date(2026, 11, 14, 12, 4, 59, 999_000_000, time.UTC),
		"2026-11-14T12:05:00Z":             time.Date(2026, 11, 14, 12, 5, 0, 0, time.UTC),
		"2026-11-14T13:04:00+01:00":        time.Date(2026, 11, 14, 12, 4, 0, 0, time.UTC),
		"1970-01-01T00:00:00+00:00":        time.Unix(0, 0).UTC(),
		"9999-12-31T23:59:59Z":             time.Time{},
	}
	for raw, want := range accepted {
		write, err := progress(t, body(fmt.Sprintf(`,"position_seconds":1,"observed_at":"%s"`, raw)), true)
		if raw == "9999-12-31T23:59:59Z" {
			if message(err) != futureMessage {
				t.Errorf("%s: %q", raw, message(err))
			}
			continue
		}
		if err != nil || write.ObservedAt == nil || !write.ObservedAt.Equal(want) || write.ObservedAt.Location() != time.UTC {
			t.Errorf("%s: %v %v", raw, write.ObservedAt, err)
		}
	}
	refused := map[string]string{
		"2026-11-07T10:00:00": timeMessage, "2026-11-07": timeMessage, "yesterday": timeMessage, "": timeMessage, " 2026-11-07T10:00:00Z": timeMessage, "2026-11-07T10:00:00Z ": timeMessage,
		"2026-11-07T10:00:00Z\\n": timeMessage, "2026-11-07 10:00:00Z": timeMessage, "2026-11-07t10:00:00z": timeMessage, "2026-11-07T10:00Z": timeMessage, "2026-11-07T10:00:00.Z": timeMessage,
		"2026-11-07T10:00:00.1234567890Z": timeMessage, "2026-11-07T24:00:00Z": timeMessage, "2026-11-07T10:60:00Z": timeMessage, "2026-11-07T10:00:60Z": timeMessage, "2026-11-07T10:00:00+24:00": timeMessage,
		"2026-11-07T10:00:00+0100": timeMessage, "2026-11-07T10:00:00+01": timeMessage, "26-11-07T10:00:00Z": timeMessage, "２０２６-11-07T10:00:00Z": timeMessage,
		"2026-02-30T10:00:00Z": timeMessage, "2026-02-29T10:00:00Z": timeMessage, "2026-13-01T10:00:00Z": timeMessage, "2026-00-10T10:00:00Z": timeMessage, "2026-04-31T10:00:00Z": timeMessage, "2026-11-00T10:00:00Z": timeMessage,
		"1582-10-10T10:00:00Z": timeMessage, "1500-02-29T10:00:00Z": timeMessage, "0000-01-01T00:00:00Z": timeMessage, "1583-01-01T00:00:00+05:00": timeMessage,
		"2026-11-14T12:05:00.001Z": futureMessage, "2026-11-14T13:06:00+01:00": futureMessage, "2027-01-01T00:00:00Z": futureMessage,
	}
	for raw, want := range refused {
		if _, err := progress(t, body(fmt.Sprintf(`,"position_seconds":1,"observed_at":"%s"`, raw)), true); message(err) != want {
			t.Errorf("%q: got %q", raw, message(err))
		}
	}
	for _, raw := range []string{`1762500000`, `1.5`, `true`, `false`, `[]`, `{}`, `["2026-11-07T10:00:00Z"]`, `{"at":"2026-11-07T10:00:00Z"}`} {
		if _, err := progress(t, body(`,"position_seconds":1,"observed_at":`+raw), true); message(err) != timeMessage {
			t.Errorf("observed_at %s: %q", raw, message(err))
		}
	}
	for _, raw := range []string{``, `,"observed_at":null`} {
		write, err := progress(t, body(`,"position_seconds":1`+raw), true)
		if err != nil || write.ObservedAt != nil {
			t.Errorf("unknown activity time %q: %v %v", raw, write.ObservedAt, err)
		}
	}
}

func TestResolveConflictIsABooleanOrAbsent(t *testing.T) {
	for raw, want := range map[string]bool{`true`: true, `false`: false, `null`: false} {
		write, err := progress(t, body(`,"position_seconds":1,"resolve_conflict":`+raw), true)
		if err != nil || write.Resolve != want {
			t.Errorf("%s: %v %v", raw, write.Resolve, err)
		}
	}
	for _, raw := range []string{`"true"`, `1`, `0`, `[true]`, `{"yes":true}`, `"false"`, `""`} {
		if _, err := progress(t, body(`,"position_seconds":1,"resolve_conflict":`+raw), true); message(err) != resolveMessage {
			t.Errorf("%s: %q", raw, message(err))
		}
	}
}

func TestRefusalsAreCheckedInTheRailsOrder(t *testing.T) {
	both := body(`,"observed_at":"nope","resolve_conflict":1,"position_seconds":-1`)
	if _, err := progress(t, both, true); message(err) != resolveMessage {
		t.Errorf("resolve before time: %q", message(err))
	}
	timeAndPosition := body(`,"observed_at":"nope","position_seconds":-1`)
	if _, err := progress(t, timeAndPosition, true); message(err) != timeMessage {
		t.Errorf("time before position: %q", message(err))
	}
	if _, err := progress(t, []byte(`{"asset_id":1,"observed_at":"nope","resolve_conflict":1}`), true); message(err) != requiredMessage {
		t.Error("required fields come first")
	}
}

func TestUnknownFieldsAreIgnoredAndDuplicateKeysTakeTheLastValue(t *testing.T) {
	write, err := progress(t, body(`,"position_seconds":1,"extra":{"a":[1]},"device":"x","position_seconds":2`), true)
	if err != nil || write.PositionSeconds == nil || *write.PositionSeconds != 2 {
		t.Fatalf("%v %v", write.PositionSeconds, err)
	}
}

func TestMalformedAndOversizedBodiesAreNotDocuments(t *testing.T) {
	for _, raw := range []string{`{`, `{"a":}`, `{"a":1}}`, `[`, "{\"a\":\"\xff\"}", `{"a":NaN}`, `{"a":1,}`, `/**/{}`, strings.Repeat("[", 101) + strings.Repeat("]", 101)} {
		if _, err := Decode([]byte(raw)); !errors.Is(err, ErrMalformed) {
			t.Errorf("%q: %v", raw, err)
		}
	}
	if _, err := Decode([]byte(strings.Repeat(" ", MaxBodyBytes+1))); !errors.Is(err, ErrMalformed) {
		t.Error("an oversized body was decoded")
	}
	if _, err := Decode([]byte(strings.Repeat(" ", MaxBodyBytes))); err != nil {
		t.Error("a body at the limit was refused")
	}
}

func TestReadingStatusNamesAreExactStrings(t *testing.T) {
	for _, name := range []string{"unread", "in_progress", "finished"} {
		document, _ := Decode([]byte(fmt.Sprintf(`{"status":"%s","other":1}`, name)))
		if got, err := document.Status(); err != nil || got != name {
			t.Errorf("%s: %q %v", name, got, err)
		}
	}
	for _, raw := range []string{`{"status":"unknown"}`, `{"status":["finished"]}`, `{"status":null}`, `{}`, `[]`, `null`, ``, `{"status":"Finished"}`, `{"status":" finished"}`, `{"status":1}`, `{"status":true}`, `{"status":{"a":"finished"}}`, `"finished"`} {
		document, err := Decode([]byte(raw))
		if err != nil {
			t.Fatalf("%q: %v", raw, err)
		}
		if _, err := document.Status(); message(err) != "Choose unread, in_progress, or finished" {
			t.Errorf("%q: %q", raw, message(err))
		}
	}
}
