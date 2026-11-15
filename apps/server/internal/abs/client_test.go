package abs

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type fakeServer struct {
	*httptest.Server
	handler func(w http.ResponseWriter, r *http.Request)
	seen    []string
	auth    []string
}

func newFake(t *testing.T, handler func(w http.ResponseWriter, r *http.Request)) *fakeServer {
	t.Helper()
	fake := &fakeServer{handler: handler}
	fake.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fake.seen = append(fake.seen, r.URL.RequestURI())
		fake.auth = append(fake.auth, r.Header.Get("Authorization"))
		fake.handler(w, r)
	}))
	t.Cleanup(fake.Close)
	return fake
}

func client(t *testing.T, fake *fakeServer, size int) *Client {
	t.Helper()
	built, err := NewClient(Config{BaseURL: fake.URL, APIKey: "synthetic-key", PageSize: size, MaxPageBytes: 1 << 16, MaxItems: 1000, RequestTimeout: 2 * time.Second})
	if err != nil {
		t.Fatal(err)
	}
	return built
}

func itemsPage(w http.ResponseWriter, total, from, to int) {
	results := []map[string]any{}
	for index := from; index < to; index++ {
		results = append(results, map[string]any{"id": fmt.Sprintf("li_%03d", index), "media": map[string]any{"metadata": map[string]any{"title": fmt.Sprintf("Title %d", index)}}})
	}
	json.NewEncoder(w).Encode(map[string]any{"results": results, "total": total, "limit": 2, "page": 0})
}

func pagedHandler(total, size int) func(w http.ResponseWriter, r *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		var page int
		fmt.Sscanf(r.URL.Query().Get("page"), "%d", &page)
		from := page * size
		to := min(from+size, total)
		if from > total {
			from = total
		}
		itemsPage(w, total, from, to)
	}
}

func TestInventoryPaginatesAcrossPages(t *testing.T) {
	fake := newFake(t, pagedHandler(5, 2))
	inventory, err := client(t, fake, 2).LibraryInventory(context.Background(), "lib-1")
	if err != nil {
		t.Fatal(err)
	}
	if inventory.Empty || len(inventory.Items) != 5 {
		t.Fatalf("got %+v", inventory)
	}
	want := []string{
		"/api/libraries/lib-1/items?limit=2&page=0",
		"/api/libraries/lib-1/items?limit=2&page=1",
		"/api/libraries/lib-1/items?limit=2&page=2",
	}
	if strings.Join(fake.seen, " ") != strings.Join(want, " ") {
		t.Fatalf("requests %v", fake.seen)
	}
	for _, header := range fake.auth {
		if header != "Bearer synthetic-key" {
			t.Fatalf("authorization %q", header)
		}
	}
}

func TestInventoryExplicitEmptyIsTheOnlyEmpty(t *testing.T) {
	fake := newFake(t, pagedHandler(0, 2))
	inventory, err := client(t, fake, 2).LibraryInventory(context.Background(), "lib")
	if err != nil || !inventory.Empty || len(inventory.Items) != 0 {
		t.Fatalf("got %+v %v", inventory, err)
	}
}

func TestInventoryNeverReportsEmptyOrCompleteForUnreliableAnswers(t *testing.T) {
	status := func(code int) func(http.ResponseWriter, *http.Request) {
		return func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(code) }
	}
	body := func(text string) func(http.ResponseWriter, *http.Request) {
		return func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, text) }
	}
	cases := []struct {
		name    string
		handler func(http.ResponseWriter, *http.Request)
		code    string
	}{
		{"server error", status(500), "http-status-500"},
		{"unauthorized", status(401), "auth-401"},
		{"forbidden", status(403), "auth-403"},
		{"redirect", func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, "http://127.0.0.1:1/x", 302) }, "redirect-302"},
		{"not found", status(404), "library-not-found-404"},
		{"gone", status(410), "library-not-found-410"},
		{"garbage", body("<html>maintenance</html>"), "malformed"},
		{"empty body", body(""), "malformed"},
		{"null", body("null"), "malformed"},
		{"results missing", body(`{"total":0}`), "malformed"},
		{"total missing", body(`{"results":[]}`), "malformed"},
		{"results null", body(`{"results":null,"total":0}`), "malformed"},
		{"negative total", body(`{"results":[],"total":-1}`), "malformed"},
		{"fractional total", body(`{"results":[],"total":1.5}`), "malformed"},
		{"text total", body(`{"results":[],"total":"0"}`), "malformed"},
		{"trailing data", body(`{"results":[],"total":0} {"x":1}`), "malformed"},
		{"empty page with positive total", body(`{"results":[],"total":3}`), "truncated"},
		{"results with zero total", body(`{"results":[{"id":"a"}],"total":0}`), "inconsistent"},
		{"item without id", body(`{"results":[{"title":"x"}],"total":1}`), "malformed"},
		{"item not an object", body(`{"results":["x"],"total":1}`), "malformed"},
		{"more than total", body(`{"results":[{"id":"a"},{"id":"b"}],"total":1}`), "inconsistent"},
		{"total beyond the limit", body(`{"results":[{"id":"a"}],"total":5000}`), "too-large"},
		{"short page before total", body(`{"results":[{"id":"a"}],"total":3}`), "truncated"},
	}
	for _, entry := range cases {
		t.Run(entry.name, func(t *testing.T) {
			fake := newFake(t, entry.handler)
			inventory, err := client(t, fake, 2).LibraryInventory(context.Background(), "lib")
			if err == nil {
				t.Fatalf("accepted %+v", inventory)
			}
			if got := CodeOf(err); got != entry.code {
				t.Fatalf("code %q, want %q", got, entry.code)
			}
			if inventory.Empty || len(inventory.Items) != 0 {
				t.Fatalf("partial result %+v", inventory)
			}
		})
	}
}

func TestInventoryDetectsInconsistencyBetweenPages(t *testing.T) {
	calls := 0
	totals := func(w http.ResponseWriter, r *http.Request) {
		calls++
		switch calls {
		case 1:
			itemsPage(w, 4, 0, 2)
		default:
			itemsPage(w, 5, 2, 4)
		}
	}
	_, err := client(t, newFake(t, totals), 2).LibraryInventory(context.Background(), "lib")
	if CodeOf(err) != CodeInconsistent {
		t.Fatalf("got %v", err)
	}
}

func TestInventoryRefusesDuplicateIdentifiers(t *testing.T) {
	handler := func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"results":[{"id":"a"},{"id":"a"}],"total":2}`)
	}
	_, err := client(t, newFake(t, handler), 2).LibraryInventory(context.Background(), "lib")
	if CodeOf(err) != CodeInconsistent {
		t.Fatalf("got %v", err)
	}
}

func TestInventoryEndlessPagesAreBounded(t *testing.T) {
	calls := 0
	fake := newFake(t, func(w http.ResponseWriter, r *http.Request) {
		calls++
		results := []map[string]any{{"id": fmt.Sprintf("a%d", calls)}, {"id": fmt.Sprintf("b%d", calls)}}
		json.NewEncoder(w).Encode(map[string]any{"results": results, "total": 3})
	})
	_, err := client(t, fake, 2).LibraryInventory(context.Background(), "lib")
	if err == nil || calls > 3 {
		t.Fatalf("calls %d err %v", calls, err)
	}
}

func TestInventoryBoundsTheResponseSize(t *testing.T) {
	handler := func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, `{"results":[{"id":"a","description":"%s"}],"total":1}`, strings.Repeat("x", 1<<17))
	}
	_, err := client(t, newFake(t, handler), 2).LibraryInventory(context.Background(), "lib")
	if CodeOf(err) != CodeTooLarge {
		t.Fatalf("got %v", err)
	}
}

func TestInventoryHangingServerIsCancelled(t *testing.T) {
	released := make(chan struct{})
	reached := make(chan struct{}, 1)
	fake := newFake(t, func(w http.ResponseWriter, r *http.Request) {
		reached <- struct{}{}
		select {
		case <-released:
		case <-r.Context().Done():
		}
	})
	defer close(released)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		_, err := client(t, fake, 2).LibraryInventory(ctx, "lib")
		done <- err
	}()
	<-reached
	cancel()
	if err := <-done; CodeOf(err) != CodeCancelled {
		t.Fatalf("got %v", err)
	}
}

func TestInventoryRequestTimeoutBoundsAHungResponse(t *testing.T) {
	released := make(chan struct{})
	fake := newFake(t, func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-released:
		case <-r.Context().Done():
		}
	})
	defer close(released)
	built, err := NewClient(Config{BaseURL: fake.URL, APIKey: "k", PageSize: 2, RequestTimeout: 100 * time.Millisecond})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := built.LibraryInventory(context.Background(), "lib"); CodeOf(err) != CodeConnection {
		t.Fatalf("got %v", err)
	}
}

func TestLibrariesListsAndValidates(t *testing.T) {
	fake := newFake(t, func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"libraries":[{"id":"l1","name":"Audio","mediaType":"book"},{"id":"l2","name":"Pods","mediaType":"podcast"}]}`)
	})
	libraries, err := client(t, fake, 2).Libraries(context.Background())
	if err != nil || len(libraries) != 2 || libraries[0] != (Library{ID: "l1", MediaType: "book"}) || libraries[1].MediaType != "podcast" {
		t.Fatalf("got %+v %v", libraries, err)
	}
	for _, body := range []string{`{}`, `{"libraries":null}`, `{"libraries":[{"name":"x"}]}`, `nope`} {
		fake.handler = func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, body) }
		if _, err := client(t, fake, 2).Libraries(context.Background()); CodeOf(err) != CodeMalformed {
			t.Fatalf("%s: %v", body, err)
		}
	}
}

func TestClientOnlyTalksToLoopback(t *testing.T) {
	built, err := NewClient(Config{BaseURL: "http://192.0.2.1:9", APIKey: "k", RequestTimeout: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := built.Libraries(context.Background()); CodeOf(err) != CodeDestination {
		t.Fatalf("got %v", err)
	}
}

func TestClientRefusesUnusableConfiguration(t *testing.T) {
	for _, config := range []Config{{BaseURL: "", APIKey: "k"}, {BaseURL: "ftp://127.0.0.1", APIKey: "k"}, {BaseURL: "http://user:pw@127.0.0.1", APIKey: "k"}, {BaseURL: "http://127.0.0.1"}} {
		if _, err := NewClient(config); CodeOf(err) != CodeConfig {
			t.Errorf("%+v: %v", config, err)
		}
	}
}

func TestInventoryRefusesLibraryIdentifiersThatCouldChangeThePath(t *testing.T) {
	fake := newFake(t, pagedHandler(0, 2))
	for _, id := range []string{"", "..", "a/b", "a?b", "a b", "../x", "a%2Fb", strings.Repeat("a", 129)} {
		if _, err := client(t, fake, 2).LibraryInventory(context.Background(), id); CodeOf(err) != CodeConfig {
			t.Errorf("%q: %v", id, err)
		}
	}
	if len(fake.seen) != 0 {
		t.Fatalf("requests %v", fake.seen)
	}
}
