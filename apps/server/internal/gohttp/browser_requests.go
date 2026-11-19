package gohttp

import (
	"context"
	"database/sql"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/consumer"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/live"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/webpreview"
)

const (
	requestsPerPage      = 25
	maxRequestPage       = 1_000_000
	maxRequestQueryRunes = 200
	unknownValue         = "unknown"
)

var requestBookTypes = map[int]string{store.BookTypeEbook: "ebook", store.BookTypeAudiobook: "audiobook", store.BookTypeComicbook: "comicbook"}

var requestStatusNames = func() map[int]string {
	names := map[int]string{}
	for name, value := range live.RequestStatuses {
		names[value] = name
	}
	return names
}()

var attentionReasons = map[string]bool{
	"Search failed before any source returned results.":                                                       true,
	"Search results found. Please review and select a result to download.":                                    true,
	"Search results found but none matched auto-select criteria. Please review and select a result manually.": true,
	"No search result selected for download":                                                                  true,
	"Download client authentication failed. Please check credentials.":                                        true,
}

var retriesExhausted = regexp.MustCompile(`^Maximum retry attempts \([0-9]{1,4}\) exceeded\. Manual intervention required\.$`)

var rubyInteger = regexp.MustCompile(`^[ \t\n\v\f\r]*([+-]?)([0-9]+(?:_[0-9]+)*)`)

type requestLibrary struct {
	State         string  `json:"state"`
	PublicationID *string `json:"publication_id,omitempty"`
}

type requester struct {
	Name string `json:"name"`
	Self bool   `json:"self"`
}

type requestSummary struct {
	ID              string           `json:"id"`
	Status          string           `json:"status"`
	AttentionNeeded bool             `json:"attention_needed"`
	Title           string           `json:"title"`
	Author          *string          `json:"author"`
	BookType        string           `json:"book_type"`
	Cover           webpreview.Cover `json:"cover"`
	DownloadPercent *int             `json:"download_percent"`
	CreatedAt       string           `json:"created_at"`
	UpdatedAt       string           `json:"updated_at"`
	CompletedAt     *string          `json:"completed_at"`
	NextRetryAt     *string          `json:"next_retry_at"`
	Library         *requestLibrary  `json:"library"`
	RequestedBy     *requester       `json:"requested_by,omitempty"`
}

type requestDownload struct {
	Status   string `json:"status"`
	Progress *int   `json:"progress"`
}

type requestDetail struct {
	requestSummary
	AttentionReason *string           `json:"attention_reason"`
	Downloads       []requestDownload `json:"downloads"`
}

type requestFilterBody struct {
	Status    *string `json:"status"`
	Attention bool    `json:"attention"`
	Query     *string `json:"q"`
}

type requestListBody struct {
	Account    string            `json:"account"`
	Scope      string            `json:"scope"`
	Filter     requestFilterBody `json:"filter"`
	Counts     map[string]int    `json:"counts"`
	Page       int               `json:"page"`
	PerPage    int               `json:"per_page"`
	Total      int               `json:"total"`
	TotalPages int               `json:"total_pages"`
	Items      []requestSummary  `json:"items"`
}

type requestQuery struct {
	filter live.RequestFilter
	page   int
}

func rubyToI(value string) int {
	parts := rubyInteger.FindStringSubmatch(value)
	if parts == nil || parts[1] == "-" {
		return 0
	}
	digits := strings.TrimLeft(strings.ReplaceAll(parts[2], "_", ""), "0")
	if len(digits) > 7 {
		return maxRequestPage
	}
	number, _ := strconv.Atoi("0" + digits)
	return number
}

func parseRequestQuery(raw string) (requestQuery, bool) {
	values, err := url.ParseQuery(raw)
	if err != nil {
		return requestQuery{}, false
	}
	parsed := requestQuery{page: 1}
	for key, found := range values {
		if len(found) != 1 && (key == "status" || key == "attention" || key == "q" || key == "page") {
			return requestQuery{}, false
		}
	}
	if status := values.Get("status"); strings.TrimSpace(status) != "" {
		if _, known := live.RequestStatuses[status]; !known && status != live.RequestFilterActive {
			return requestQuery{}, false
		}
		parsed.filter.Status = status
	}
	parsed.filter.Attention = values.Get("attention") == "true"
	query := values.Get("q")
	if !utf8.ValidString(query) {
		return requestQuery{}, false
	}
	query = strings.Trim(query, " \t\n\v\f\r\x00")
	if runes := []rune(query); len(runes) > maxRequestQueryRunes {
		query = string(runes[:maxRequestQueryRunes])
	}
	parsed.filter.Query = query
	parsed.page = min(max(rubyToI(values.Get("page")), 1), maxRequestPage)
	return parsed, true
}

func (a *App) requestScope(session browserSession) live.RequestScope {
	return live.RequestScope{UserID: session.user.ID, All: session.user.Admin}
}

func scopeName(scope live.RequestScope) string {
	if scope.All {
		return "all"
	}
	return "own"
}

func (a *App) webRequests(w http.ResponseWriter, r *http.Request, session browserSession, result *outcome) {
	query, ok := parseRequestQuery(r.URL.RawQuery)
	if !ok {
		problem(w, result, http.StatusUnprocessableEntity, "invalid_query")
		return
	}
	scope := a.requestScope(session)
	page, err := a.db.Requests(r.Context(), scope, query.filter, query.page, requestsPerPage)
	if err != nil {
		mapFailure(w, result, err)
		return
	}
	libraries, err := a.requestLibraries(r.Context(), session.user.ID, page.Rows)
	if err != nil {
		mapFailure(w, result, err)
		return
	}
	items := make([]requestSummary, 0, len(page.Rows))
	for _, row := range page.Rows {
		item, err := summariseRequest(row, page.Progress, libraries, session)
		if err != nil {
			mapFailure(w, result, err)
			return
		}
		items = append(items, item)
	}
	body := requestListBody{
		Account: session.account(), Scope: scopeName(scope), Filter: filterBody(query.filter),
		Counts: map[string]int{"attention": page.Counts.Attention, "active": page.Counts.Active},
		Page:   page.Page, PerPage: requestsPerPage, Total: page.Total, TotalPages: page.Pages, Items: items,
	}
	result.set(http.StatusOK, "")
	writeJSON(w, http.StatusOK, body)
}

func filterBody(filter live.RequestFilter) requestFilterBody {
	body := requestFilterBody{Attention: filter.Attention}
	if filter.Status != "" {
		body.Status = &filter.Status
	}
	if filter.Query != "" {
		body.Query = &filter.Query
	}
	return body
}

func (a *App) webRequest(w http.ResponseWriter, r *http.Request, session browserSession, rawID string, result *outcome) {
	id, err := strconv.ParseInt(rawID, 10, 64)
	if !bookID.MatchString(rawID) || err != nil {
		problem(w, result, http.StatusNotFound, "not_found")
		return
	}
	found, err := a.db.Request(r.Context(), a.requestScope(session), id)
	if err != nil {
		mapFailure(w, result, err)
		return
	}
	if found == nil {
		problem(w, result, http.StatusNotFound, "not_found")
		return
	}
	libraries, err := a.requestLibraries(r.Context(), session.user.ID, []live.RequestRow{found.Row})
	if err != nil {
		mapFailure(w, result, err)
		return
	}
	summary, err := summariseRequest(found.Row, found.Progress, libraries, session)
	if err != nil {
		mapFailure(w, result, err)
		return
	}
	detail := requestDetail{requestSummary: summary, AttentionReason: attentionReason(found.Row), Downloads: make([]requestDownload, 0, len(found.Downloads))}
	for _, download := range found.Downloads {
		detail.Downloads = append(detail.Downloads, projectDownload(download))
	}
	result.set(http.StatusOK, "")
	writeJSON(w, http.StatusOK, map[string]any{"account": session.account(), "request": detail})
}

func projectDownload(download live.DownloadRow) requestDownload {
	status, known := live.DownloadStatuses[download.Status]
	if !known {
		status = unknownValue
	}
	projected := requestDownload{Status: status}
	if (status == "queued" || status == "downloading") && download.Progress.Valid {
		value := int(min(max(download.Progress.Int64, 0), 100))
		projected.Progress = &value
	}
	return projected
}

func attentionReason(row live.RequestRow) *string {
	if !row.Attention || !row.IssueDescription.Valid {
		return nil
	}
	reason := row.IssueDescription.String
	if attentionReasons[reason] || retriesExhausted.MatchString(reason) {
		return &reason
	}
	return nil
}

func (a *App) requestLibraries(ctx context.Context, userID int64, rows []live.RequestRow) (map[int64]*requestLibrary, error) {
	libraries := map[int64]*requestLibrary{}
	var roots []string
	for _, row := range rows {
		book := row.Book
		if _, seen := libraries[book.ID]; seen || !book.FilePath.Valid || strings.TrimSpace(book.FilePath.String) == "" {
			continue
		}
		if _, served := requestBookTypes[book.BookType]; !served {
			libraries[book.ID] = &requestLibrary{State: "unavailable"}
			continue
		}
		if roots == nil {
			resolved, err := a.resolveRoots(ctx)
			if err != nil {
				return nil, err
			}
			roots = resolved
		}
		opens, err := a.detailOpens(ctx, userID, roots, book)
		if err != nil {
			return nil, err
		}
		if !opens {
			libraries[book.ID] = &requestLibrary{State: "unavailable"}
			continue
		}
		id := strconv.FormatInt(book.ID, 10)
		libraries[book.ID] = &requestLibrary{State: "available", PublicationID: &id}
	}
	return libraries, nil
}

func summariseRequest(row live.RequestRow, progress map[int64]int, libraries map[int64]*requestLibrary, session browserSession) (requestSummary, error) {
	status, known := requestStatusNames[row.Status]
	if !known {
		status = unknownValue
	}
	bookType, known := requestBookTypes[row.Book.BookType]
	if !known {
		bookType = unknownValue
	}
	created, err := isoTimestamp(row.CreatedAt)
	if err != nil {
		return requestSummary{}, err
	}
	updated, err := isoTimestamp(row.UpdatedAt)
	if err != nil {
		return requestSummary{}, err
	}
	completed, err := optionalTimestamp(row.CompletedAt)
	if err != nil {
		return requestSummary{}, err
	}
	retry, err := optionalTimestamp(row.NextRetryAt)
	if err != nil {
		return requestSummary{}, err
	}
	bookID := strconv.FormatInt(row.Book.ID, 10)
	cover, err := consumer.SafeCover(row.Book.CoverURL)
	if err != nil {
		cover = nil
	}
	summary := requestSummary{
		ID: strconv.FormatInt(row.ID, 10), Status: status, AttentionNeeded: row.Attention, Title: row.Book.Title, BookType: bookType,
		Cover: webpreview.Cover{URL: cover, Style: webpreview.CoverStyle(bookID)}, CreatedAt: created, UpdatedAt: updated, CompletedAt: completed, NextRetryAt: retry,
		Library: libraries[row.Book.ID],
	}
	if row.Book.Author.Valid && strings.TrimSpace(row.Book.Author.String) != "" {
		summary.Author = &row.Book.Author.String
	}
	if value, found := progress[row.ID]; found && status == "downloading" {
		summary.DownloadPercent = &value
	}
	if session.user.Admin {
		summary.RequestedBy = &requester{Name: row.RequesterName.String, Self: row.UserID == session.user.ID}
	}
	return summary, nil
}

func isoTimestamp(text string) (string, error) {
	moment, err := store.ParseTimestamp(text)
	if err != nil {
		return "", err
	}
	return store.FormatISO8601Millis(moment), nil
}

func optionalTimestamp(value sql.NullString) (*string, error) {
	if !value.Valid {
		return nil, nil
	}
	text, err := isoTimestamp(value.String)
	if err != nil {
		return nil, err
	}
	return &text, nil
}
