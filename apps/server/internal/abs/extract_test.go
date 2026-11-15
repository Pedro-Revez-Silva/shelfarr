package abs

import (
	"bytes"
	"encoding/json"
	"os"
	"reflect"
	"strconv"
	"testing"
)

type corpusEntry struct {
	Name string `json:"name"`
	Raw  any    `json:"raw"`
}

func decodeUsingNumbers(t *testing.T, data []byte, target any) {
	t.Helper()
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if err := decoder.Decode(target); err != nil {
		t.Fatal(err)
	}
}

func textOf(value any) any {
	switch typed := value.(type) {
	case nil:
		return nil
	case string:
		return typed
	case json.Number:
		return typed.String()
	case float64:
		return strconv.FormatFloat(typed, 'f', -1, 64)
	}
	return value
}

func asText(pointer *string) any {
	if pointer == nil {
		return nil
	}
	return *pointer
}

func TestExtractionMatchesRubyOracle(t *testing.T) {
	corpusBytes, err := os.ReadFile("testdata/extract-corpus.json")
	if err != nil {
		t.Fatal(err)
	}
	expectedBytes, err := os.ReadFile("testdata/extract-expected.json")
	if err != nil {
		t.Fatal(err)
	}
	var corpus []corpusEntry
	var expected []map[string]any
	decodeUsingNumbers(t, corpusBytes, &corpus)
	decodeUsingNumbers(t, expectedBytes, &expected)
	if len(corpus) != len(expected) || len(corpus) < 30 {
		t.Fatalf("corpus and oracle output disagree: %d vs %d", len(corpus), len(expected))
	}
	for index, entry := range corpus {
		item, err := parseItem(entry.Raw)
		if err != nil {
			t.Errorf("%s: %v", entry.Name, err)
			continue
		}
		want := expected[index]
		got := map[string]any{
			"audiobookshelf_id": item.ID,
			"title":             asText(item.Title),
			"subtitle":          asText(item.Subtitle),
			"author":            asText(item.Author),
			"narrator":          asText(item.Narrator),
			"series":            asText(item.Series),
			"series_position":   asText(item.SeriesNumber),
			"publisher":         asText(item.Publisher),
			"language":          asText(item.Language),
			"description":       asText(item.Description),
			"isbn":              asText(item.ISBN),
			"asin":              asText(item.ASIN),
			"missing":           item.Missing,
		}
		if item.PublishedYear == nil {
			got["published_year"] = nil
		} else {
			got["published_year"] = strconv.FormatInt(*item.PublishedYear, 10)
		}
		normalised := map[string]any{}
		for key, value := range want {
			normalised[key] = textOf(value)
		}
		if !reflect.DeepEqual(got, normalised) {
			t.Errorf("%s:\n got  %v\n want %v", entry.Name, got, normalised)
		}
	}
}

func TestExtractionRefusesUnsupportedShapes(t *testing.T) {
	cases := map[string]any{
		"not-an-object":     "text",
		"no-id":             map[string]any{"title": "x"},
		"blank-id":          map[string]any{"id": "  "},
		"object-title":      map[string]any{"id": "a", "title": map[string]any{"x": 1}},
		"boolean-true-name": map[string]any{"id": "a", "title": true},
		"array-description": map[string]any{"id": "a", "description": []any{"x"}},
	}
	for name, raw := range cases {
		if _, err := parseItem(raw); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}
