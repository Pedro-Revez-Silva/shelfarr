package gohttp

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"regexp"
	"strconv"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/acquisition"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/admission"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/live"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/strictjson"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/wfstore"
)

const maxAcquisitionBody = 1024

var (
	errSessionGone  = errors.New("session ended")
	offeredWorkID   = regexp.MustCompile(`^OL[1-9][0-9]{0,11}W$`)
	storedRecordID  = regexp.MustCompile(`^[1-9][0-9]{0,18}$`)
	requestBodyKeys = map[string]bool{"work_id": true, "book_type": true}
)

type sessionBound struct {
	store   *wfstore.Store
	session browserSession
}

func (s sessionBound) Transact(ctx context.Context, fn func(tx *sql.Tx) error) error {
	return s.store.Transact(ctx, func(tx *sql.Tx) error {
		var present int
		err := tx.QueryRowContext(ctx, `SELECT 1 FROM sessions WHERE id = ? AND user_id = ?`, s.session.row.ID, s.session.user.ID).Scan(&present)
		if errors.Is(err, sql.ErrNoRows) {
			return errSessionGone
		}
		if err != nil {
			return err
		}
		return fn(tx)
	})
}

func strictMembers(body []byte, allowed map[string]bool) (strictjson.Value, bool) {
	parsed, err := strictjson.Parse(body)
	if err != nil || parsed.Kind != strictjson.Object {
		return strictjson.Value{}, false
	}
	for _, key := range parsed.Keys {
		if !allowed[key] {
			return strictjson.Value{}, false
		}
	}
	return parsed, true
}

func requestedWork(body []byte) (string, bool) {
	parsed, ok := strictMembers(body, requestBodyKeys)
	if !ok {
		return "", false
	}
	work, _ := parsed.Member("work_id")
	kind, _ := parsed.Member("book_type")
	if work.Kind != strictjson.String || !offeredWorkID.MatchString(work.Text) || kind.Kind != strictjson.String || kind.Text != "ebook" {
		return "", false
	}
	return work.Text, true
}

func submissionBody(work offeredWork) ([]byte, error) {
	body := map[string]any{"work_id": "openlibrary:" + work.work.ID, "book_type": "ebook", "title": work.work.Title}
	if work.work.Author != "" {
		body["author"] = work.work.Author
	}
	if cover := work.work.CoverURL(); cover != "" {
		body["cover_url"] = cover
	}
	if work.work.FirstPublishYear > 0 && work.work.FirstPublishYear <= 3000 {
		body["year"] = work.work.FirstPublishYear
	}
	return json.Marshal(body)
}

func (a *App) storeFailure(w http.ResponseWriter, result *outcome, err error) {
	switch {
	case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		mapFailure(w, result, err)
	case wfstore.CodeOf(err) == wfstore.CodeBusy:
		w.Header().Set("Retry-After", "1")
		problem(w, result, http.StatusServiceUnavailable, "database_busy")
	default:
		problem(w, result, http.StatusServiceUnavailable, "database_unavailable")
	}
}

func (a *App) webCreateRequest(w http.ResponseWriter, r *http.Request, session browserSession, result *outcome) {
	body, failure := a.readLimitedBody(w, r, maxAcquisitionBody)
	if failure != nil {
		a.writeBodyFailure(w, result, failure)
		return
	}
	workID, ok := requestedWork(body)
	if !ok {
		problem(w, result, http.StatusUnprocessableEntity, "invalid_request")
		return
	}
	work, offered := a.acquisition.offers.lookup(session.user.ID, workID)
	if !offered {
		problem(w, result, http.StatusUnprocessableEntity, "work_not_offered")
		return
	}
	encoded, err := submissionBody(offeredWork{work: work})
	if err != nil {
		problem(w, result, http.StatusInternalServerError, "internal_error")
		return
	}
	submission, err := admission.ParseSubmission(encoded)
	if err != nil {
		problem(w, result, http.StatusUnprocessableEntity, "invalid_request")
		return
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), a.config.RequestTimeout)
	defer cancel()
	decided, err := admission.Submit(ctx, sessionBound{store: a.acquisition.store, session: session}, session.user.ID, submission, a.now)
	switch {
	case errors.Is(err, errSessionGone), errors.Is(err, admission.ErrAccountUnavailable):
		problem(w, result, http.StatusUnauthorized, "signed_out")
		return
	case errors.Is(err, admission.ErrInvalid), errors.Is(err, admission.ErrUnsupported):
		problem(w, result, http.StatusUnprocessableEntity, "invalid_request")
		return
	case errors.Is(err, admission.ErrSchemaUnsupported):
		problem(w, result, http.StatusNotImplemented, "unsupported_schema")
		return
	case errors.Is(err, admission.ErrStoredValue):
		problem(w, result, http.StatusNotImplemented, "unsupported_stored_value")
		return
	case err != nil:
		a.storeFailure(w, result, err)
		return
	}
	answer := map[string]any{"account": session.account(), "outcome": string(decided.Outcome)}
	status := http.StatusOK
	switch decided.Outcome {
	case admission.Created:
		status = http.StatusCreated
		answer["request"] = map[string]string{"id": strconv.FormatInt(decided.RequestID, 10)}
		answer["warnings"] = append([]string{}, decided.Warnings...)
		a.acquisition.nudge()
	case admission.Existing:
		answer["request"] = map[string]string{"id": strconv.FormatInt(decided.RequestID, 10)}
	case admission.AlreadyInLibrary:
		answer["library"] = a.openablePublication(ctx, session.user.ID, decided.PublicationID)
	}
	result.set(status, "")
	writeJSON(w, status, answer)
}

func (a *App) openablePublication(ctx context.Context, userID, publicationID int64) any {
	book, err := a.db.AcquiredBook(ctx, publicationID, allBookTypes)
	if err != nil || book == nil {
		return nil
	}
	roots, err := a.resolveRoots(ctx)
	if err != nil {
		return nil
	}
	opens, err := a.detailOpens(ctx, userID, roots, *book)
	if err != nil || !opens {
		return nil
	}
	return map[string]string{"publication_id": strconv.FormatInt(publicationID, 10)}
}

type selectionBody struct {
	State    string  `json:"state"`
	ResultID string  `json:"result_id"`
	Code     *string `json:"code"`
}

type searchBody struct {
	State   string `json:"state"`
	Code    string `json:"code"`
	RetryAt string `json:"retry_at"`
}

type candidateBody struct {
	ID    string `json:"id"`
	Title string `json:"title"`
}

func projectSelection(job selectionJob) *selectionBody {
	body := &selectionBody{State: job.state, ResultID: strconv.FormatInt(job.resultID, 10)}
	if job.code != "" {
		code := job.code
		body.Code = &code
	}
	return body
}

func (a *App) adminRequest(w http.ResponseWriter, r *http.Request, session browserSession, rawID string, result *outcome) (*live.RequestDetail, bool) {
	id, err := strconv.ParseInt(rawID, 10, 64)
	if !session.user.Admin || !storedRecordID.MatchString(rawID) || err != nil {
		problem(w, result, http.StatusNotFound, "not_found")
		return nil, false
	}
	found, err := a.db.Request(r.Context(), live.RequestScope{UserID: session.user.ID, All: true}, id)
	if err != nil {
		mapFailure(w, result, err)
		return nil, false
	}
	if found == nil {
		problem(w, result, http.StatusNotFound, "not_found")
		return nil, false
	}
	return found, true
}

func (a *App) webAcquisition(w http.ResponseWriter, r *http.Request, session browserSession, rawID string, result *outcome) {
	found, ok := a.adminRequest(w, r, session, rawID, result)
	if !ok {
		return
	}
	requestID := found.Row.ID
	candidates := []candidateBody{}
	if found.Row.Book.BookType == store.BookTypeEbook {
		listed, err := acquisition.SelectableCandidates(r.Context(), a.acquisition.store, requestID)
		if err != nil {
			a.storeFailure(w, result, err)
			return
		}
		for _, candidate := range listed {
			candidates = append(candidates, candidateBody{ID: strconv.FormatInt(candidate.ResultID, 10), Title: candidate.Title})
		}
	}
	status, known := requestStatusNames[found.Row.Status]
	if !known {
		status = unknownValue
	}
	answer := map[string]any{
		"account":    session.account(),
		"request":    map[string]string{"id": strconv.FormatInt(requestID, 10), "status": status},
		"candidates": candidates,
		"selection":  nil,
		"search":     nil,
	}
	if job, found := a.acquisition.selection(requestID); found {
		answer["selection"] = projectSelection(job)
	}
	if note, parked := a.acquisition.searchNote(requestID); parked && status == "pending" {
		answer["search"] = searchBody{State: note.state, Code: note.code, RetryAt: store.FormatISO8601Millis(note.until)}
	}
	result.set(http.StatusOK, "")
	writeJSON(w, http.StatusOK, answer)
}

func chosenResult(body []byte) (int64, bool) {
	parsed, ok := strictMembers(body, map[string]bool{"result_id": true})
	if !ok {
		return 0, false
	}
	value, _ := parsed.Member("result_id")
	if value.Kind != strictjson.String || !storedRecordID.MatchString(value.Text) {
		return 0, false
	}
	id, err := strconv.ParseInt(value.Text, 10, 64)
	return id, err == nil
}

func (a *App) webSelectResult(w http.ResponseWriter, r *http.Request, session browserSession, rawID string, result *outcome) {
	found, ok := a.adminRequest(w, r, session, rawID, result)
	if !ok {
		return
	}
	body, failure := a.readLimitedBody(w, r, maxAcquisitionBody)
	if failure != nil {
		a.writeBodyFailure(w, result, failure)
		return
	}
	resultID, ok := chosenResult(body)
	if !ok {
		problem(w, result, http.StatusUnprocessableEntity, "invalid_request")
		return
	}
	requestID := found.Row.ID
	plan, err := acquisition.PlanSelection(r.Context(), a.acquisition.store, requestID, resultID)
	if refusal := acquisition.SelectionRefusal(err); refusal != nil {
		result.set(http.StatusConflict, "not_selectable")
		writeJSON(w, http.StatusConflict, map[string]string{"error": "not_selectable", "reason": refusal.Error()})
		return
	}
	if err != nil {
		a.storeFailure(w, result, err)
		return
	}
	if plan.Completed != 0 {
		result.set(http.StatusOK, "")
		writeJSON(w, http.StatusOK, map[string]any{"account": session.account(), "selection": projectSelection(selectionJob{resultID: resultID, state: selectionCompleted})})
		return
	}
	job, err := a.acquisition.enqueue(selectionJob{requestID: requestID, resultID: resultID, sessionID: session.row.ID, userID: session.user.ID})
	if errors.Is(err, errAcquisitionBusy) {
		problem(w, result, http.StatusConflict, "acquisition_busy")
		return
	}
	result.set(http.StatusAccepted, "")
	writeJSON(w, http.StatusAccepted, map[string]any{"account": session.account(), "selection": projectSelection(job)})
}
