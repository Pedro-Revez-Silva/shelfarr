package netguard

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"syscall"
	"time"
)

var (
	ErrDestination = errors.New("destination is not loopback")
	ErrTooLarge    = errors.New("response exceeds limit")
	ErrRedirect    = errors.New("redirect refused")
)

func loopbackOnly(network, address string, _ syscall.RawConn) error {
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		return ErrDestination
	}
	if ip := net.ParseIP(host); ip == nil || !ip.IsLoopback() {
		return ErrDestination
	}
	return nil
}

func NewClient(timeout time.Duration) *http.Client {
	dialer := &net.Dialer{Timeout: timeout, Control: loopbackOnly}
	transport := &http.Transport{
		Proxy:                 nil,
		DialContext:           dialer.DialContext,
		DisableKeepAlives:     true,
		ResponseHeaderTimeout: timeout,
		TLSHandshakeTimeout:   timeout,
	}
	return &http.Client{
		Transport: transport,
		Timeout:   timeout,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
}

func ValidateBaseURL(raw string) (*url.URL, error) {
	parsed, err := url.Parse(raw)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Hostname() == "" || parsed.User != nil {
		return nil, errors.New("invalid base url")
	}
	return parsed, nil
}

func ReadLimited(ctx context.Context, body io.Reader, limit int64) ([]byte, error) {
	data, err := io.ReadAll(io.LimitReader(body, limit+1))
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, ErrTooLarge
	}
	return data, nil
}

func IsRedirect(status int) bool {
	return status >= 300 && status < 400
}
