//go:build e2e

package workflows

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
)

type fakeLibrary struct {
	ID        string
	MediaType string
	Items     []map[string]any
}

type absPeer struct {
	*httptest.Server
	mutex     sync.Mutex
	libraries []*fakeLibrary
	requests  []string
	hook      func(library string, page int, w http.ResponseWriter, r *http.Request) bool
}

func newABS(t *testing.T, libraries ...*fakeLibrary) *absPeer {
	t.Helper()
	peer := &absPeer{libraries: libraries}
	mux := http.NewServeMux()
	mux.HandleFunc("/api/libraries", func(w http.ResponseWriter, r *http.Request) {
		if !peer.authorised(w, r) {
			return
		}
		peer.record(r)
		var listed []map[string]any
		for _, entry := range peer.libraries {
			listed = append(listed, map[string]any{"id": entry.ID, "name": "Name " + entry.ID, "mediaType": entry.MediaType, "folders": []any{}})
		}
		json.NewEncoder(w).Encode(map[string]any{"libraries": listed})
	})
	mux.HandleFunc("/api/libraries/", func(w http.ResponseWriter, r *http.Request) {
		if !peer.authorised(w, r) {
			return
		}
		peer.record(r)
		id := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/api/libraries/"), "/items")
		page, _ := strconv.Atoi(r.URL.Query().Get("page"))
		limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
		if peer.hook != nil && peer.hook(id, page, w, r) {
			return
		}
		peer.mutex.Lock()
		var found *fakeLibrary
		for _, entry := range peer.libraries {
			if entry.ID == id {
				found = entry
			}
		}
		var results []map[string]any
		total := 0
		if found != nil {
			total = len(found.Items)
			from := min(page*limit, total)
			results = found.Items[from:min(from+limit, total)]
		}
		peer.mutex.Unlock()
		if found == nil {
			w.WriteHeader(404)
			return
		}
		if results == nil {
			results = []map[string]any{}
		}
		json.NewEncoder(w).Encode(map[string]any{"results": results, "total": total, "limit": limit, "page": page})
	})
	peer.Server = httptest.NewServer(mux)
	t.Cleanup(peer.Close)
	return peer
}

func (p *absPeer) authorised(w http.ResponseWriter, r *http.Request) bool {
	if r.Header.Get("Authorization") != "Bearer "+absKey {
		w.WriteHeader(401)
		return false
	}
	return true
}

func (p *absPeer) record(r *http.Request) {
	p.mutex.Lock()
	p.requests = append(p.requests, r.URL.RequestURI())
	p.mutex.Unlock()
}

func (p *absPeer) itemRequests(library string) int {
	p.mutex.Lock()
	defer p.mutex.Unlock()
	total := 0
	for _, request := range p.requests {
		if strings.HasPrefix(request, "/api/libraries/"+library+"/items") {
			total++
		}
	}
	return total
}

func absItem(id, title string) map[string]any {
	return map[string]any{
		"id": id, "isMissing": false,
		"media": map[string]any{"metadata": map[string]any{
			"title": title, "subtitle": "Sub " + id, "authorName": "Author " + id, "narratorName": "Narrator " + id,
			"series": []any{map[string]any{"name": "Series", "sequence": "2"}}, "publisher": "Pub", "language": "en",
			"description": "About " + title, "isbn": "978" + id, "asin": "B" + id, "publishedYear": "2001",
		}},
	}
}

func libraryOf(id string, titles ...string) *fakeLibrary {
	entry := &fakeLibrary{ID: id, MediaType: "book"}
	for _, title := range titles {
		entry.Items = append(entry.Items, absItem(id+"-"+strings.ReplaceAll(strings.ToLower(title), " ", "-"), title))
	}
	return entry
}

type torrentState struct {
	Name     string
	Progress float64
	State    string
	Size     int64
	Content  string
	Save     string
	Missing  bool
}

type qbitPeer struct {
	*httptest.Server
	mutex    sync.Mutex
	torrents map[string]*torrentState
	logins   int
	inflight int
	maxSeen  int
	hook     func(hash string, w http.ResponseWriter, r *http.Request) bool
	override func(hash string, w http.ResponseWriter, r *http.Request) bool
}

func newQBit(t *testing.T) *qbitPeer {
	t.Helper()
	peer := &qbitPeer{torrents: map[string]*torrentState{}}
	mux := http.NewServeMux()
	mux.HandleFunc("/api/v2/auth/login", func(w http.ResponseWriter, r *http.Request) {
		r.ParseForm()
		peer.mutex.Lock()
		peer.logins++
		peer.mutex.Unlock()
		if r.Form.Get("username") != "synthetic" || r.Form.Get("password") != qbitPassword {
			fmt.Fprint(w, "Fails.")
			return
		}
		http.SetCookie(w, &http.Cookie{Name: "SID", Value: "synthetic-session"})
		fmt.Fprint(w, "Ok.")
	})
	mux.HandleFunc("/api/v2/torrents/info", func(w http.ResponseWriter, r *http.Request) {
		if cookie, err := r.Cookie("SID"); err != nil || cookie.Value != "synthetic-session" {
			w.WriteHeader(403)
			return
		}
		hash := r.URL.Query().Get("hashes")
		peer.mutex.Lock()
		peer.inflight++
		peer.maxSeen = max(peer.maxSeen, peer.inflight)
		peer.mutex.Unlock()
		defer func() {
			peer.mutex.Lock()
			peer.inflight--
			peer.mutex.Unlock()
		}()
		if peer.hook != nil && peer.hook(hash, w, r) {
			return
		}
		peer.mutex.Lock()
		state, found := peer.torrents[hash]
		peer.mutex.Unlock()
		if !found || state.Missing {
			fmt.Fprint(w, "[]")
			return
		}
		json.NewEncoder(w).Encode([]map[string]any{{
			"hash": hash, "name": state.Name, "progress": state.Progress, "state": state.State, "size": state.Size,
			"content_path": state.Content, "save_path": state.Save,
		}})
	})
	peer.Server = httptest.NewServer(mux)
	t.Cleanup(peer.Close)
	return peer
}

func (p *qbitPeer) set(hash string, state torrentState) {
	p.mutex.Lock()
	defer p.mutex.Unlock()
	copyOf := state
	p.torrents[hash] = &copyOf
}

type consumer struct {
	*httptest.Server
	mutex    sync.Mutex
	received []string
	effects  map[string]int
	status   int
	hook     func(key string, w http.ResponseWriter, r *http.Request) bool
}

func newConsumer(t *testing.T) *consumer {
	t.Helper()
	peer := &consumer{effects: map[string]int{}, status: 200}
	peer.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		key := r.Header.Get("Idempotency-Key")
		if peer.hook != nil && peer.hook(key, w, r) {
			return
		}
		peer.mutex.Lock()
		defer peer.mutex.Unlock()
		peer.received = append(peer.received, key)
		if peer.status != 200 {
			w.WriteHeader(peer.status)
			return
		}
		peer.effects[key]++
		w.WriteHeader(200)
	}))
	t.Cleanup(peer.Close)
	return peer
}

func (c *consumer) deliveries() []string {
	c.mutex.Lock()
	defer c.mutex.Unlock()
	return append([]string(nil), c.received...)
}

func (c *consumer) localEffects() map[string]int {
	c.mutex.Lock()
	defer c.mutex.Unlock()
	copyOf := map[string]int{}
	for key := range c.effects {
		copyOf[key] = 1
	}
	return copyOf
}

type seeded struct {
	Request  int64
	Result   int64
	Download int64
	Client   int64
	Hash     string
}

func (w *workdir) seedClient(db *sql.DB, peerURL, password string, enabled bool) int64 {
	w.t.Helper()
	enabledFlag := 0
	if enabled {
		enabledFlag = 1
	}
	return exec1(w.t, db, `INSERT INTO download_clients (name, client_type, url, username, password, enabled, priority, created_at, updated_at) VALUES (?, 'qbittorrent', ?, 'synthetic', ?, ?, 0, datetime('now'), datetime('now'))`,
		fmt.Sprintf("qbit-%d", exec1Count(w.t, db)+1), peerURL, w.encrypt(password), enabledFlag)
}

func exec1Count(t *testing.T, db *sql.DB) int64 {
	return scalar[int64](t, db, `SELECT COUNT(*) FROM download_clients`)
}

func (w *workdir) seedDownload(db *sql.DB, client int64, hash string) seeded {
	w.t.Helper()
	request := exec1(w.t, db, `INSERT INTO requests (user_id, book_id, status, created_at, updated_at) VALUES (1, 1, 3, datetime('now'), datetime('now'))`)
	result := exec1(w.t, db, `INSERT INTO search_results (request_id, guid, title, status, created_at, updated_at) VALUES (?, ?, 'Synthetic release', 1, datetime('now'), datetime('now'))`, request, "guid-"+hash)
	download := exec1(w.t, db, `INSERT INTO downloads (request_id, search_result_id, download_client_id, external_id, download_type, status, progress, name, created_at, updated_at) VALUES (?, ?, ?, ?, 'torrent', 1, 0, 'Synthetic', '2026-01-01 00:00:00.000000', '2026-01-01 00:00:00.000000')`,
		request, result, strconv.FormatInt(client, 10), hash)
	return seeded{Request: request, Result: result, Download: download, Client: client, Hash: hash}
}

func hashOf(index int) string {
	return fmt.Sprintf("%040x", 0xabc000+index)
}
