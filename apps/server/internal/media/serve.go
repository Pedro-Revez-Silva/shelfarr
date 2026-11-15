package media

import (
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

const chunkSize = 64 << 10

type Asset struct {
	ID        string
	Filename  string
	MediaType string
	Size      int64
}

func etagMatches(header string, etag string) bool {
	for _, value := range strings.Split(header, ",") {
		value = strings.TrimSpace(value)
		if value == etag || value == "W/"+etag || value == "*" {
			return true
		}
	}
	return false
}

func Serve(w http.ResponseWriter, r *http.Request, file *os.File, asset Asset, stall time.Duration) int64 {
	etag := `"` + asset.ID + `"`
	header := w.Header()
	header.Set("Cache-Control", "private, no-store")
	header.Set("Accept-Ranges", "bytes")
	header.Set("ETag", etag)
	header.Set("X-Content-Type-Options", "nosniff")
	header.Set("Content-Type", asset.MediaType)
	header.Set("Content-Disposition", ContentDisposition("inline", asset.Filename))
	header.Set("Content-Transfer-Encoding", "binary")
	if etagMatches(strings.Join(r.Header.Values("If-None-Match"), ", "), etag) {
		w.WriteHeader(http.StatusNotModified)
		return 0
	}
	rangeHeader := strings.Join(r.Header.Values("Range"), ", ")
	if ifRange := strings.Join(r.Header.Values("If-Range"), ", "); strings.TrimSpace(ifRange) != "" && ifRange != etag {
		rangeHeader = ""
	}
	span := Span{First: 0, Last: asset.Size - 1}
	partial := false
	if r.Method != http.MethodHead && strings.TrimSpace(rangeHeader) != "" {
		parsed, ok := ParseRange(rangeHeader, asset.Size)
		if !ok {
			header.Set("Content-Range", "bytes */"+strconv.FormatInt(asset.Size, 10))
			w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
			return 0
		}
		span, partial = parsed, true
	}
	length := span.Length()
	header.Set("Content-Length", strconv.FormatInt(length, 10))
	status := http.StatusOK
	if partial {
		header.Set("Content-Range", "bytes "+strconv.FormatInt(span.First, 10)+"-"+strconv.FormatInt(span.Last, 10)+"/"+strconv.FormatInt(asset.Size, 10))
		status = http.StatusPartialContent
	}
	w.WriteHeader(status)
	if r.Method == http.MethodHead {
		return 0
	}
	return copyBounded(w, io.NewSectionReader(file, span.First, length), stall)
}

func copyBounded(w http.ResponseWriter, source io.Reader, stall time.Duration) int64 {
	controller := http.NewResponseController(w)
	buffer := make([]byte, chunkSize)
	var written int64
	for {
		count, readErr := source.Read(buffer)
		if count > 0 {
			controller.SetWriteDeadline(time.Now().Add(stall))
			if _, err := w.Write(buffer[:count]); err != nil {
				return written
			}
			written += int64(count)
		}
		if readErr != nil {
			controller.SetWriteDeadline(time.Time{})
			return written
		}
	}
}
