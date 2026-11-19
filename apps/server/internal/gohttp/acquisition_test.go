package gohttp

import (
	"net/http"
	"strconv"
	"testing"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/openlibrary"
)

func TestRequestRoutesStayAsTheyWereWithoutAnAcquisitionVolume(t *testing.T) {
	h := newHarness(t, nil)
	cases := []struct {
		method, path string
		status       int
		allow        string
	}{
		{http.MethodPost, "/preview/api/v1/requests", http.StatusMethodNotAllowed, "GET"},
		{http.MethodPut, "/preview/api/v1/requests", http.StatusMethodNotAllowed, "GET"},
		{http.MethodGet, "/preview/api/v1/requests/1/acquisition", http.StatusNotFound, ""},
		{http.MethodPost, "/preview/api/v1/requests/1/acquisition", http.StatusNotFound, ""},
		{http.MethodPost, "/preview/api/v1/requests/1/selection", http.StatusNotFound, ""},
		{http.MethodGet, "/preview/api/v1/requests/1/selection", http.StatusNotFound, ""},
	}
	for _, entry := range cases {
		recorder := h.do(entry.method, entry.path, nil)
		if recorder.Code != entry.status || recorder.Header().Get("Allow") != entry.allow {
			t.Errorf("%s %s answered %d Allow %q", entry.method, entry.path, recorder.Code, recorder.Header().Get("Allow"))
		}
	}
}

func TestAnAcquisitionVolumeAddsOnlyItsOwnRoutes(t *testing.T) {
	h := newHarness(t, nil)
	h.app.acquisition = &acquisitionService{}
	cases := []struct {
		method, path string
		status       int
		allow        string
	}{
		{http.MethodPut, "/preview/api/v1/requests", http.StatusMethodNotAllowed, "GET, POST"},
		{http.MethodPost, "/preview/api/v1/requests/1/acquisition", http.StatusMethodNotAllowed, "GET"},
		{http.MethodGet, "/preview/api/v1/requests/1/selection", http.StatusMethodNotAllowed, "POST"},
		{http.MethodPost, "/preview/api/v1/requests", http.StatusNotFound, ""},
		{http.MethodGet, "/preview/api/v1/requests/1/acquisition", http.StatusNotFound, ""},
		{http.MethodGet, "/preview/api/v1/requests/1/candidates", http.StatusNotFound, ""},
		{http.MethodPost, "/api/consumer/v1/requests", http.StatusNotImplemented, ""},
	}
	for _, entry := range cases {
		recorder := h.do(entry.method, entry.path, nil)
		if recorder.Code != entry.status || recorder.Header().Get("Allow") != entry.allow {
			t.Errorf("%s %s answered %d Allow %q", entry.method, entry.path, recorder.Code, recorder.Header().Get("Allow"))
		}
	}
}

func TestARequestNamesOneOpenLibraryEbookAndNothingElse(t *testing.T) {
	accepted := map[string]string{
		`{"work_id":"OL9001W","book_type":"ebook"}`:                     "OL9001W",
		`{"book_type":"ebook","work_id":"OL123456789012W"}`:             "OL123456789012W",
		`{"work_id":"OL1W","work_id":"OL2W","book_type":"ebook"}`:       "OL2W",
		" \n{\"work_id\":\"OL7W\",\"book_type\":\"ebook\"}\n":           "OL7W",
		`{"work_id":"OL9001W","book_type":"ebook","book_type":"ebook"}`: "OL9001W",
	}
	for body, want := range accepted {
		if got, ok := requestedWork([]byte(body)); !ok || got != want {
			t.Errorf("%s: %q %v", body, got, ok)
		}
	}
	for _, body := range []string{
		``, `null`, `[]`, `"OL1W"`, `{}`,
		`{"work_id":"OL9001W"}`,
		`{"work_id":"OL9001W","book_type":"audiobook"}`,
		`{"work_id":"OL9001W","book_type":"ebook","title":"Injected"}`,
		`{"work_id":"openlibrary:OL9001W","book_type":"ebook"}`,
		`{"work_id":"/works/OL9001W","book_type":"ebook"}`,
		`{"work_id":"OL0W","book_type":"ebook"}`,
		`{"work_id":"OL1234567890123W","book_type":"ebook"}`,
		`{"work_id":"ol9001w","book_type":"ebook"}`,
		`{"work_id":"OL9001M","book_type":"ebook"}`,
		`{"work_id":9001,"book_type":"ebook"}`,
		`{"work_id":"OL9001W","book_type":"ebook"} {}`,
	} {
		if got, ok := requestedWork([]byte(body)); ok {
			t.Errorf("%s accepted as %q", body, got)
		}
	}
}

func TestAChoiceNamesOneStoredResult(t *testing.T) {
	if id, ok := chosenResult([]byte(`{"result_id":"42"}`)); !ok || id != 42 {
		t.Errorf("a stored id: %d %v", id, ok)
	}
	for _, body := range []string{`{"result_id":42}`, `{"result_id":"0"}`, `{"result_id":"042"}`, `{"result_id":"-1"}`, `{"result_id":"9223372036854775808"}`, `{"result_id":"1","request_id":"2"}`, `{}`, `[]`} {
		if id, ok := chosenResult([]byte(body)); ok {
			t.Errorf("%s accepted as %d", body, id)
		}
	}
}

func TestOfferedWorksBelongToOneAccountExpireAndStayBounded(t *testing.T) {
	now := time.Date(2026, 11, 19, 10, 0, 0, 0, time.UTC)
	offers := newOfferedWorks(func() time.Time { return now })
	offers.remember(1, []openlibrary.Work{{ID: "OL1W", Title: "One"}})
	if work, found := offers.lookup(1, "OL1W"); !found || work.Title != "One" {
		t.Fatalf("an offered work was not remembered")
	}
	if _, found := offers.lookup(2, "OL1W"); found {
		t.Errorf("another account may request a work it was never shown")
	}
	now = now.Add(offerLifetime + time.Second)
	if _, found := offers.lookup(1, "OL1W"); found {
		t.Errorf("an expired offer is still accepted")
	}
	var many []openlibrary.Work
	for index := 0; index < maxOffersPerPerson+50; index++ {
		now = now.Add(time.Millisecond)
		many = append(many, openlibrary.Work{ID: "OL" + strconv.Itoa(index+1) + "W"})
		offers.remember(1, many[len(many)-1:])
	}
	if held := len(offers.accounts[1]); held != maxOffersPerPerson {
		t.Errorf("%d offers held for one account", held)
	}
	if _, found := offers.lookup(1, "OL1W"); found {
		t.Errorf("the oldest offer survived the bound")
	}
	if _, found := offers.lookup(1, "OL"+strconv.Itoa(maxOffersPerPerson+50)+"W"); !found {
		t.Errorf("the newest offer was dropped")
	}
	for account := int64(10); account < 10+maxOfferedAccounts+5; account++ {
		now = now.Add(time.Millisecond)
		offers.remember(account, []openlibrary.Work{{ID: "OL1W"}})
	}
	if len(offers.accounts) > maxOfferedAccounts {
		t.Errorf("%d accounts held", len(offers.accounts))
	}
}

func TestATransientSearchFailureBacksOffAndARefusalWaitsLonger(t *testing.T) {
	now := time.Date(2026, 11, 19, 10, 0, 0, 0, time.UTC)
	service := &acquisitionService{now: func() time.Time { return now }, parked: map[int64]parkedSearch{}, jobs: map[int64]*selectionJob{}}
	var waits []time.Duration
	for range 6 {
		service.backOff(7, "provider-busy")
		note, _ := service.searchNote(7)
		waits = append(waits, note.until.Sub(now))
	}
	want := []time.Duration{time.Minute, 2 * time.Minute, 4 * time.Minute, 8 * time.Minute, 15 * time.Minute, 15 * time.Minute}
	for index := range want {
		if waits[index] != want[index] {
			t.Fatalf("back-off %v, want %v", waits, want)
		}
	}
	service.park(8, searchRefused, "provider_disabled", refusedSearchWait)
	if note, _ := service.searchNote(8); note.state != searchRefused || note.until.Sub(now) != refusedSearchWait {
		t.Errorf("refusal note %+v", note)
	}
	service.unpark(7)
	if _, found := service.searchNote(7); found {
		t.Errorf("a settled search kept its note")
	}
}

func TestOneChosenDownloadAtATimeAndARepeatIsTheSameChoice(t *testing.T) {
	service := &acquisitionService{now: time.Now, parked: map[int64]parkedSearch{}, jobs: map[int64]*selectionJob{}, wake: make(chan struct{}, 1)}
	first, err := service.enqueue(selectionJob{requestID: 1, resultID: 9})
	if err != nil || first.state != selectionQueued {
		t.Fatalf("first choice %+v %v", first, err)
	}
	if again, err := service.enqueue(selectionJob{requestID: 1, resultID: 9}); err != nil || again != first {
		t.Errorf("a repeated choice %+v %v", again, err)
	}
	if _, err := service.enqueue(selectionJob{requestID: 1, resultID: 10}); err != errAcquisitionBusy {
		t.Errorf("a different choice while one is queued: %v", err)
	}
	if _, err := service.enqueue(selectionJob{requestID: 2, resultID: 11}); err != errAcquisitionBusy {
		t.Errorf("another request's choice while one is queued: %v", err)
	}
	running, found := service.nextSelection()
	if !found || running.state != selectionDownloading {
		t.Fatalf("the worker did not take the choice: %+v", running)
	}
	if _, found := service.nextSelection(); found {
		t.Errorf("one choice was handed out twice")
	}
	service.finish(selectionFailed, "provider-busy")
	if job, _ := service.selection(1); job.state != selectionFailed || job.code != "provider-busy" {
		t.Errorf("finished job %+v", job)
	}
	if retried, err := service.enqueue(selectionJob{requestID: 1, resultID: 10}); err != nil || retried.state != selectionQueued || retried.resultID != 10 {
		t.Errorf("a new choice after a failure %+v %v", retried, err)
	}
}

func TestOnlyLoopbackBrowserOriginsQualify(t *testing.T) {
	for origin, want := range map[string]bool{
		"http://127.0.0.1:3100": true, "http://[::1]:3100": true, "http://127.8.0.1": true,
		"http://localhost:3100": false, "https://shelf.example": false, "": false, "http://10.0.0.1:3100": false,
	} {
		if got := loopbackOrigin(origin); got != want {
			t.Errorf("%q: %v", origin, got)
		}
	}
}
