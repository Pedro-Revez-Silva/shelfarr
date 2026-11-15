package abs

import (
	"encoding/json"
	"regexp"
	"strconv"
	"strings"
)

type Item struct {
	ID            string
	Title         *string
	Subtitle      *string
	Author        *string
	Narrator      *string
	Series        *string
	SeriesNumber  *string
	Publisher     *string
	Language      *string
	Description   *string
	ISBN          *string
	ASIN          *string
	PublishedYear *int64
	Missing       bool
}

type object = map[string]any

var yearPattern = regexp.MustCompile(`\d{4}`)

func isObject(value any) (object, bool) {
	typed, ok := value.(object)
	return typed, ok
}

func dig(value any, path ...string) any {
	current := value
	for _, key := range path {
		typed, ok := isObject(current)
		if !ok {
			return nil
		}
		current = typed[key]
	}
	return current
}

func firstSet(values ...any) any {
	for _, value := range values {
		if value == nil || value == false {
			continue
		}
		return value
	}
	return nil
}

func present(value any) bool {
	switch typed := value.(type) {
	case nil:
		return false
	case bool:
		return typed
	case string:
		return strings.TrimSpace(typed) != ""
	case []any:
		return len(typed) > 0
	case object:
		return len(typed) > 0
	}
	return true
}

func firstPresent(values ...any) any {
	for _, value := range values {
		if present(value) {
			return value
		}
	}
	return nil
}

func scalar(value any) (*string, error) {
	switch typed := value.(type) {
	case nil:
		return nil, nil
	case string:
		return &typed, nil
	case json.Number:
		text := typed.String()
		return &text, nil
	}
	return nil, errMalformedValue
}

func joinNames(value any, keys ...string) (any, error) {
	if !present(value) {
		return nil, nil
	}
	list, isList := value.([]any)
	if !isList {
		return value, nil
	}
	allText := true
	for _, entry := range list {
		if _, ok := entry.(string); !ok {
			allText = false
		}
	}
	var names []string
	for _, entry := range list {
		if allText {
			names = append(names, entry.(string))
			continue
		}
		typed, ok := isObject(entry)
		if !ok {
			continue
		}
		var name any
		for _, key := range keys {
			if name = typed[key]; name != nil && name != false {
				break
			}
		}
		if name == nil || name == false {
			continue
		}
		text, err := scalar(name)
		if err != nil {
			return nil, err
		}
		names = append(names, *text)
	}
	joined := strings.Join(names, ", ")
	return joined, nil
}

func firstSeries(raw, metadata any) any {
	series := firstSet(dig(metadata, "series"), dig(raw, "series"), dig(raw, "book", "metadata", "series"))
	if list, ok := series.([]any); ok {
		if len(list) == 0 {
			return nil
		}
		return list[0]
	}
	return series
}

func bookMetadata(raw any) any {
	if metadata := firstSet(dig(raw, "media", "metadata"), dig(raw, "metadata"), dig(raw, "book", "metadata")); metadata != nil {
		return metadata
	}
	return object{}
}

func extractAuthor(raw any) (any, error) {
	if value := firstPresent(
		dig(raw, "author"),
		dig(raw, "authorName"),
		dig(raw, "media", "metadata", "authorName"),
		dig(raw, "media", "author"),
		dig(raw, "metadata", "authorName"),
		dig(raw, "book", "author"),
		dig(raw, "book", "metadata", "authorName"),
	); value != nil {
		return value, nil
	}
	return joinNames(firstSet(
		dig(raw, "media", "authors"),
		dig(raw, "media", "metadata", "authors"),
		dig(raw, "metadata", "authors"),
		dig(raw, "book", "metadata", "authors"),
	), "name", "fullName", "author")
}

func extractNarrator(raw any) (any, error) {
	if value := firstPresent(
		dig(raw, "narrator"),
		dig(raw, "narratorName"),
		dig(raw, "media", "metadata", "narratorName"),
		dig(raw, "metadata", "narratorName"),
		dig(raw, "book", "metadata", "narratorName"),
	); value != nil {
		return value, nil
	}
	narrators := firstSet(
		dig(raw, "media", "metadata", "narrators"),
		dig(raw, "metadata", "narrators"),
		dig(raw, "book", "metadata", "narrators"),
	)
	joined, err := joinNames(narrators, "name", "fullName")
	if err != nil || joined == nil {
		return joined, err
	}
	if text, ok := joined.(string); ok && text == "" {
		if _, isList := narrators.([]any); isList {
			return nil, nil
		}
	}
	return joined, nil
}

func extractSeriesName(raw, metadata any) any {
	if value := firstPresent(dig(raw, "seriesName"), dig(metadata, "seriesName")); value != nil {
		return value
	}
	series := firstSeries(raw, metadata)
	if value := firstPresent(dig(series, "name"), dig(series, "series", "name")); value != nil {
		return value
	}
	switch typed := series.(type) {
	case string:
		if present(typed) {
			return typed
		}
	case json.Number:
		return typed
	}
	return nil
}

func extractSeriesNumber(raw, metadata any) any {
	if value := firstPresent(dig(raw, "seriesSequence")); value != nil {
		return value
	}
	series := firstSeries(raw, metadata)
	if _, ok := isObject(series); ok {
		return firstPresent(dig(series, "sequence"))
	}
	return nil
}

func extractYear(raw, metadata any) (*int64, error) {
	value := firstSet(
		dig(metadata, "publishedYear"),
		dig(metadata, "publishedDate"),
		dig(raw, "publishedYear"),
		dig(raw, "publishedDate"),
		dig(raw, "year"),
	)
	if !present(value) {
		return nil, nil
	}
	text, err := scalar(value)
	if err != nil || text == nil {
		return nil, err
	}
	match := yearPattern.FindString(*text)
	if match == "" {
		return nil, nil
	}
	year, err := strconv.ParseInt(match, 10, 64)
	if err != nil {
		return nil, err
	}
	return &year, nil
}

func normalizeIdentifier(value any) (*string, error) {
	if !present(value) {
		return nil, nil
	}
	if list, ok := value.([]any); ok {
		for _, entry := range list {
			if present(entry) {
				return scalar(entry)
			}
		}
		return nil, nil
	}
	return scalar(value)
}

func textField(value any) (*string, error) {
	if value == nil || value == false {
		return nil, nil
	}
	return scalar(value)
}

func parseItem(raw any) (Item, error) {
	if _, ok := isObject(raw); !ok {
		return Item{}, errMalformedValue
	}
	metadata := bookMetadata(raw)
	identity, err := textField(firstSet(dig(raw, "id"), dig(raw, "media", "id"), dig(raw, "item", "id")))
	if err != nil || identity == nil || strings.TrimSpace(*identity) == "" {
		return Item{}, errMalformedValue
	}
	item := Item{ID: *identity, Missing: dig(raw, "isMissing") == true}
	assign := func(target **string, value any) {
		if err == nil {
			*target, err = textField(value)
		}
	}
	assign(&item.Title, firstSet(dig(raw, "title"), dig(metadata, "title"), dig(raw, "media", "title"), dig(raw, "book", "title")))
	assign(&item.Subtitle, firstSet(dig(raw, "subtitle"), dig(metadata, "subtitle"), dig(raw, "media", "subtitle"), dig(raw, "book", "subtitle")))
	if err == nil {
		var author, narrator any
		if author, err = extractAuthor(raw); err == nil {
			assign(&item.Author, author)
		}
		if err == nil {
			if narrator, err = extractNarrator(raw); err == nil {
				assign(&item.Narrator, narrator)
			}
		}
	}
	assign(&item.Series, extractSeriesName(raw, metadata))
	assign(&item.SeriesNumber, extractSeriesNumber(raw, metadata))
	assign(&item.Publisher, firstSet(dig(metadata, "publisher"), dig(raw, "publisher")))
	assign(&item.Language, firstSet(dig(metadata, "language"), dig(raw, "language")))
	assign(&item.Description, firstSet(dig(metadata, "description"), dig(raw, "description")))
	assign(&item.ASIN, firstSet(dig(metadata, "asin"), dig(raw, "asin")))
	if err == nil {
		item.ISBN, err = normalizeIdentifier(firstSet(dig(metadata, "isbn"), dig(raw, "isbn")))
	}
	if err == nil {
		item.PublishedYear, err = extractYear(raw, metadata)
	}
	if err != nil {
		return Item{}, err
	}
	return item, nil
}
