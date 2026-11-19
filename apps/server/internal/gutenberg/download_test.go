package gutenberg

import (
	"bytes"
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/netguard"
)

func downloadClient(t *testing.T, handler http.HandlerFunc) (*Client, string) {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	origin, err := ParseOrigin(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	return &Client{Origin: origin, HTTP: netguard.NewClient(2 * time.Second), RequestTimeout: 2 * time.Second}, server.URL
}

func TestDownloadStreamsOnlyABoundedBookFromTheConfiguredOrigin(t *testing.T) {
	book := []byte("PK\x03\x04 synthetic")
	cases := []struct {
		name    string
		path    string
		handler http.HandlerFunc
		limit   int64
		code    string
	}{
		{"book", "/ebooks/1.epub", func(w http.ResponseWriter, r *http.Request) {
			if r.Header.Get("User-Agent") != userAgent {
				w.WriteHeader(418)
				return
			}
			w.Header().Set("Content-Type", "application/epub+zip")
			w.Write(book)
		}, 64, ""},
		{"no content type", "/ebooks/1.epub", func(w http.ResponseWriter, r *http.Request) { w.Header()["Content-Type"] = nil; w.Write(book) }, 64, ""},
		{"exactly the limit", "/ebooks/1.epub", func(w http.ResponseWriter, r *http.Request) { w.Write(book) }, int64(len(book)), ""},
		{"one byte over the limit", "/ebooks/1.epub", func(w http.ResponseWriter, r *http.Request) { w.Write(book) }, int64(len(book)) - 1, CodeTooLarge},
		{"announced over the limit", "/ebooks/1.epub", func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Length", "1000")
			w.WriteHeader(200)
		}, 64, CodeTooLarge},
		{"missing", "/ebooks/1.epub", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(404) }, 64, CodeRefused},
		{"redirect", "/ebooks/1.epub", func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, "/elsewhere", http.StatusFound) }, 64, CodeRefused},
		{"too many requests", "/ebooks/1.epub", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(429) }, 64, CodeBusy},
		{"server error", "/ebooks/1.epub", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(502) }, 64, CodeBusy},
		{"html", "/ebooks/1.epub", func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "TEXT/HTML; charset=utf-8")
			w.Write(book)
		}, 64, CodeNotBook},
		{"xhtml", "/ebooks/1.epub", func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/xhtml+xml")
			w.Write(book)
		}, 64, CodeNotBook},
		{"json", "/ebooks/1.epub", func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/problem+json")
			w.Write(book)
		}, 64, CodeNotBook},
		{"cut short", "/ebooks/1.epub", func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Length", strconv.Itoa(len(book)+10))
			w.WriteHeader(200)
			w.Write(book)
			connection, _, _ := w.(http.Hijacker).Hijack()
			connection.Close()
		}, 64, CodeTruncated},
	}
	for _, entry := range cases {
		t.Run(entry.name, func(t *testing.T) {
			client, origin := downloadClient(t, entry.handler)
			var received bytes.Buffer
			written, err := client.Download(context.Background(), origin+entry.path, &received, entry.limit)
			var provider *Error
			switch {
			case entry.code == "" && (err != nil || written != int64(len(book)) || !bytes.Equal(received.Bytes(), book)):
				t.Errorf("got %d bytes, %v", written, err)
			case entry.code != "" && (!errors.As(err, &provider) || provider.Code != entry.code):
				t.Errorf("got %v, want %s", err, entry.code)
			}
		})
	}
}

func TestDownloadRefusesALinkOffTheOriginWithoutContactingIt(t *testing.T) {
	contacted := false
	client, origin := downloadClient(t, func(w http.ResponseWriter, r *http.Request) { contacted = true })
	for _, link := range []string{"http://127.0.0.2:1/ebooks/1.epub", origin + "/ebooks/../1.epub", origin + "/ebooks/1.epub?x=1", "/ebooks/1.epub", origin + "//evil/1.epub"} {
		var received bytes.Buffer
		_, err := client.Download(context.Background(), link, &received, 64)
		var provider *Error
		if !errors.As(err, &provider) || provider.Code != CodeRefused {
			t.Errorf("%s: %v", link, err)
		}
	}
	if contacted {
		t.Error("the catalogue was contacted")
	}
}

type failingWriter struct{}

func (failingWriter) Write([]byte) (int, error) { return 0, errors.New("disk full") }

func TestDownloadReportsALocalWriteFailureAsItself(t *testing.T) {
	client, origin := downloadClient(t, func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("PK\x03\x04")) })
	_, err := client.Download(context.Background(), origin+"/ebooks/1.epub", failingWriter{}, 64)
	var provider *Error
	if err == nil || errors.As(err, &provider) || err.Error() != "disk full" {
		t.Errorf("got %v", err)
	}
}
