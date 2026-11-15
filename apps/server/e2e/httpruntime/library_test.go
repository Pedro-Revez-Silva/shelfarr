//go:build e2e

package httpruntime

import (
	"bufio"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"math/rand"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"syscall"
	"testing"
	"time"
)

func execSQL(t *testing.T, path, statement string, arguments ...any) {
	t.Helper()
	database, err := sql.Open("sqlite", "file:"+path+"?_pragma=busy_timeout(5000)")
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	if _, err := database.Exec(statement, arguments...); err != nil {
		t.Fatalf("sql: %v", err)
	}
}

type privateLibrary struct {
	root    string
	files   map[string]string
	bookIDs map[string]int64
}

func pseudoRandom(seed int64, length int) []byte {
	data := make([]byte, length)
	rand.New(rand.NewSource(seed)).Read(data)
	return data
}

func hexSum(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func newPrivateLibrary(t *testing.T, copied runtimeCopy, bigBytes int) privateLibrary {
	t.Helper()
	base := t.TempDir()
	root, err := filepath.EvalSymlinks(base)
	if err != nil {
		t.Fatal(err)
	}
	root = filepath.Join(root, "library")
	if err := os.MkdirAll(filepath.Join(root, "serial"), 0o700); err != nil {
		t.Fatal(err)
	}
	library := privateLibrary{root: root, files: map[string]string{}, bookIDs: map[string]int64{}}
	write := func(key, relative string, data []byte) {
		path := filepath.Join(root, relative)
		if err := os.WriteFile(path, data, 0o600); err != nil {
			t.Fatal(err)
		}
		library.files[key] = path
	}
	write("epub", "A Generated Book.epub", pseudoRandom(1, 90_000))
	write("audio", "A Generated Listen.mp3", pseudoRandom(2, bigBytes))
	write("track1", "serial/Part 1.mp3", pseudoRandom(3, 5000))
	write("track2", "serial/Part 2.mp3", pseudoRandom(4, 6000))
	library.files["serial"] = filepath.Join(root, "serial")
	execSQL(t, copied.database, `DELETE FROM consumer_progresses`)
	execSQL(t, copied.database, `DELETE FROM consumer_reading_states`)
	execSQL(t, copied.database, `DELETE FROM books`)
	for _, key := range []string{"audiobook_output_path", "ebook_output_path", "comicbook_output_path"} {
		execSQL(t, copied.database, `UPDATE settings SET value = ? WHERE key = ?`, root, key)
	}
	for index, entry := range []struct {
		key, title string
		bookType   int
	}{{"epub", "Generated Book", 1}, {"audio", "Generated Listen", 0}, {"serial", "Generated Serial", 0}} {
		identifier := int64(9001 + index)
		execSQL(t, copied.database, `INSERT INTO books (id, title, author, book_type, file_path, created_at, updated_at) VALUES (?, ?, 'Synthetic', ?, ?, '2026-11-01 00:00:00', '2026-11-01 00:00:00')`, identifier, entry.title, entry.bookType, library.files[entry.key])
		library.bookIDs[entry.key] = identifier
	}
	return library
}

type assetInfo struct {
	ID        string `json:"id"`
	Filename  string `json:"filename"`
	MediaType string `json:"media_type"`
	Size      int64  `json:"size_bytes"`
	URL       string `json:"content_url"`
}

func (s *server) assets(t *testing.T, f fixture, bookID int64) []assetInfo {
	t.Helper()
	response := s.do("GET", "/api/consumer/v1/library/"+strconv.FormatInt(bookID, 10), bearer(f, "alice-full"))
	if response.status != 200 {
		t.Fatalf("publication %d: %d %s", bookID, response.status, response.body)
	}
	var publication struct {
		Assets []assetInfo `json:"assets"`
	}
	if err := json.Unmarshal(response.body, &publication); err != nil {
		t.Fatal(err)
	}
	return publication.Assets
}

func smallReceiveBuffer(t *testing.T, address string) *net.TCPConn {
	t.Helper()
	dialer := net.Dialer{Control: func(network, address string, connection syscall.RawConn) error {
		return connection.Control(func(descriptor uintptr) {
			syscall.SetsockoptInt(int(descriptor), syscall.SOL_SOCKET, syscall.SO_RCVBUF, 2048)
		})
	}, Timeout: 5 * time.Second}
	connection, err := dialer.Dial("tcp", address)
	if err != nil {
		t.Fatal(err)
	}
	return connection.(*net.TCPConn)
}

func bufioReader(connection net.Conn) *bufio.Reader { return bufio.NewReader(connection) }
