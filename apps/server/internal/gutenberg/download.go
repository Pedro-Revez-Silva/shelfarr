package gutenberg

import (
	"context"
	"errors"
	"io"
	"mime"
	"net/http"
	"strings"
)

const (
	CodeNotBook   = "download-not-a-book"
	CodeTruncated = "download-truncated"
)

func (c *Client) Download(ctx context.Context, link string, destination io.Writer, limit int64) (int64, error) {
	resource, authorized := c.Origin.Authorize(link)
	if !authorized || resource != link {
		return 0, fail(CodeRefused)
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, resource, nil)
	if err != nil {
		return 0, fail(CodeRefused)
	}
	request.Header.Set("User-Agent", userAgent)
	response, err := c.HTTP.Do(request)
	if err != nil {
		return 0, transportFailure(ctx, err)
	}
	defer response.Body.Close()
	switch {
	case response.StatusCode == http.StatusRequestTimeout || response.StatusCode == http.StatusTooEarly || response.StatusCode == http.StatusTooManyRequests || response.StatusCode >= 500:
		return 0, fail(CodeBusy)
	case response.StatusCode != http.StatusOK:
		return 0, fail(CodeRefused)
	case textual(response.Header.Get("Content-Type")):
		return 0, fail(CodeNotBook)
	case response.ContentLength > limit:
		return 0, fail(CodeTooLarge)
	}
	target := &sink{writer: destination}
	written, err := io.Copy(target, io.LimitReader(response.Body, limit+1))
	switch {
	case target.err != nil:
		return written, target.err
	case err == nil && written > limit:
		return written, fail(CodeTooLarge)
	case errors.Is(err, io.ErrUnexpectedEOF):
		return written, fail(CodeTruncated)
	case err != nil && ctx.Err() != nil:
		return written, ctx.Err()
	case err != nil:
		return written, transportFailure(ctx, err)
	}
	return written, nil
}

type sink struct {
	writer io.Writer
	err    error
}

func (s *sink) Write(data []byte) (int, error) {
	count, err := s.writer.Write(data)
	if err != nil {
		s.err = err
	}
	return count, err
}

func textual(contentType string) bool {
	media, _, err := mime.ParseMediaType(contentType)
	if err != nil {
		media = strings.ToLower(strings.TrimSpace(strings.SplitN(contentType, ";", 2)[0]))
	}
	return strings.HasPrefix(media, "text/") || strings.Contains(media, "html") || strings.Contains(media, "json") || strings.Contains(media, "xml")
}
