package catalogue

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"slices"
	"strconv"
	"strings"
	"unicode"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/live"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/railsmsg"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/readerformats"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
)

const (
	cursorPurpose = "consumer-library"
	cursorSalt    = "consumer-catalog-v1"
	maxCursor     = 4096
	maxSearch     = 200
	defaultLimit  = 30
	maxLimit      = 50
)

type Invalid struct{ Message string }

func (e Invalid) Error() string { return e.Message }

type Result struct {
	Books      []store.Book
	NextCursor *string
}

type Catalogue struct {
	DB       *live.DB
	verifier railsmsg.Verifier
}

func New(database *live.DB, secretKeyBase string) (Catalogue, error) {
	verifier, err := railsmsg.NewVerifier(secretKeyBase, cursorSalt)
	if err != nil {
		return Catalogue{}, err
	}
	return Catalogue{DB: database, verifier: verifier}, nil
}

func normalisedLimit(param Param) int {
	if !param.IsString || len(param.Value) == 0 || len(param.Value) > 3 {
		return defaultLimit
	}
	for _, character := range param.Value {
		if character < '0' || character > '9' {
			return defaultLimit
		}
	}
	number, _ := strconv.Atoi(param.Value)
	return min(max(number, 1), maxLimit)
}

func ReadingTypes(kind string, graphic bool) []int {
	reading := []int{store.BookTypeEbook}
	if graphic {
		reading = append(reading, store.BookTypeComicbook)
	}
	switch kind {
	case "ebook":
		return reading
	case "audiobook":
		return []int{store.BookTypeAudiobook}
	}
	return append(reading, store.BookTypeAudiobook)
}

var statusNames = []string{"unread", "in_progress", "finished"}

func (c Catalogue) Call(ctx context.Context, userID int64, params Params, formats readerformats.Formats) (Result, error) {
	if !params.Type.Blank() && !(params.Type.IsString && (params.Type.Value == "ebook" || params.Type.Value == "audiobook")) {
		return Result{}, Invalid{"Unknown publication type"}
	}
	query := ""
	if params.Q.Present {
		if !params.Q.IsString || len(params.Q.Value) > maxSearch {
			return Result{}, Invalid{"Search is too long"}
		}
		query = params.Q.Value
	}
	if !params.Status.Blank() && !(params.Status.IsString && slices.Contains(statusNames, params.Status.Value)) {
		return Result{}, Invalid{"Unknown reading status"}
	}
	sort := "recent"
	if !params.Sort.Blank() {
		if !params.Sort.IsString || (params.Sort.Value != "recent" && params.Sort.Value != "title") {
			return Result{}, Invalid{"Unknown library sort"}
		}
		sort = params.Sort.Value
	}
	limit := normalisedLimit(params.Limit)
	kind, status := params.Type.Value, params.Status.Value
	parts := []string{strconv.FormatInt(userID, 10), query, kind, status, sort}
	if !formats.Default() {
		parts = append(parts, formats.Joined())
	}
	digest := sha256.Sum256([]byte(strings.Join(parts, "\x00")))
	key := hex.EncodeToString(digest[:])
	selection := live.CatalogueQuery{UserID: userID, Types: ReadingTypes(kind, formats.Graphic()), Sort: sort, Limit: limit + 1}
	if !params.Status.Blank() {
		selection.Status = status
	}
	if strings.TrimFunc(query, unicode.IsSpace) != "" {
		selection.Search = query
	}
	if err := c.applyCursor(&selection, params.Cursor, key); err != nil {
		return Result{}, err
	}
	rows, err := c.DB.Catalogue(ctx, selection)
	if err != nil {
		return Result{}, err
	}
	more := len(rows) > limit
	if more {
		rows = rows[:limit]
	}
	result := Result{Books: make([]store.Book, len(rows))}
	for index, row := range rows {
		result.Books[index] = row.Book
	}
	if more {
		last := rows[len(rows)-1]
		boundary := strconv.FormatInt(last.Book.ID, 10)
		if sort == "title" {
			boundary = "[" + railsmsg.Quote(last.TitleSort) + "," + boundary + "]"
		}
		token, err := c.verifier.Generate(json.RawMessage(`{"key":`+railsmsg.Quote(key)+`,"before":`+boundary+`}`), cursorPurpose)
		if err != nil {
			return Result{}, err
		}
		result.NextCursor = &token
	}
	return result, nil
}

var errInvalidCursor = Invalid{"Invalid library cursor"}

func (c Catalogue) applyCursor(selection *live.CatalogueQuery, cursor Param, key string) error {
	if cursor.Blank() {
		return nil
	}
	if !cursor.IsString || len(cursor.Value) > maxCursor {
		return errInvalidCursor
	}
	data, ok := c.verifier.Verified(cursor.Value, cursorPurpose)
	if !ok {
		return errInvalidCursor
	}
	var payload struct {
		Key    string          `json:"key"`
		Before json.RawMessage `json:"before"`
	}
	if err := json.Unmarshal(data, &payload); err != nil || payload.Key != key {
		return errInvalidCursor
	}
	if selection.Sort == "title" {
		boundary, ok := titleBoundary(payload.Before)
		if !ok {
			return errInvalidCursor
		}
		selection.Title = boundary
		return nil
	}
	identifier, ok := positiveInteger(payload.Before)
	if !ok {
		return errInvalidCursor
	}
	selection.Recent = identifier
	return nil
}

func positiveInteger(raw json.RawMessage) (int64, bool) {
	text := string(bytes.TrimSpace(raw))
	if text == "" || text[0] < '1' || text[0] > '9' {
		return 0, false
	}
	number, err := strconv.ParseInt(text, 10, 64)
	return number, err == nil && number > 0
}

func titleBoundary(raw json.RawMessage) (*live.TitleBoundary, bool) {
	var elements []json.RawMessage
	if err := json.Unmarshal(raw, &elements); err != nil || len(elements) != 2 {
		return nil, false
	}
	var sortKey string
	if err := json.Unmarshal(elements[0], &sortKey); err != nil {
		return nil, false
	}
	identifier, ok := positiveInteger(elements[1])
	if !ok {
		return nil, false
	}
	return &live.TitleBoundary{Sort: sortKey, ID: identifier}, true
}
