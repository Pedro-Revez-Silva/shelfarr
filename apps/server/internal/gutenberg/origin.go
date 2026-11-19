package gutenberg

import (
	"errors"
	"net"
	"net/url"
	"regexp"
	"strconv"
	"strings"
)

const maxLinkBytes = 2048

var (
	ErrOrigin         = errors.New("the catalogue address is not a plain http or https origin")
	ErrOriginExternal = errors.New("the catalogue address is not a loopback address")

	safePath = regexp.MustCompile(`\A(?:/(?:[A-Za-z0-9\-._~!$&'()*+,;=:@]|%[0-9A-Fa-f]{2})*)+\z`)
)

type Origin struct {
	text string
	host string
}

func ParseOrigin(raw string) (Origin, error) {
	parsed, err := url.Parse(RubyStrip(raw))
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Opaque != "" || parsed.User != nil {
		return Origin{}, ErrOrigin
	}
	if parsed.Hostname() == "" || (parsed.Path != "" && parsed.Path != "/") || parsed.RawQuery != "" || parsed.Fragment != "" || parsed.RawFragment != "" {
		return Origin{}, ErrOrigin
	}
	text := parsed.Scheme + "://" + parsed.Host
	if port := parsed.Port(); port != "" {
		number, err := strconv.Atoi(port)
		if err != nil || number < 1 || number > 65535 {
			return Origin{}, ErrOrigin
		}
		if (parsed.Scheme == "http" && number == 80) || (parsed.Scheme == "https" && number == 443) {
			text = parsed.Scheme + "://" + bracketed(parsed.Hostname())
		}
	}
	return Origin{text: text, host: parsed.Hostname()}, nil
}

func bracketed(host string) string {
	if strings.Contains(host, ":") {
		return "[" + host + "]"
	}
	return host
}

func (o Origin) String() string { return o.text }

func (o Origin) Loopback() bool {
	address := net.ParseIP(o.host)
	return address != nil && address.IsLoopback()
}

func (o Origin) Authorize(href string) (string, bool) {
	link := strings.ReplaceAll(RubyStrip(href), " ", "%20")
	if len(link) > maxLinkBytes {
		return "", false
	}
	if strings.HasPrefix(link, o.text+"/") {
		link = strings.TrimPrefix(link, o.text)
	}
	if strings.HasPrefix(link, "//") || !safePath.MatchString(link) {
		return "", false
	}
	for _, segment := range strings.Split(link, "/") {
		if segment == "." || segment == ".." || strings.EqualFold(segment, "%2e") || strings.EqualFold(segment, "%2e%2e") || strings.EqualFold(segment, ".%2e") || strings.EqualFold(segment, "%2e.") {
			return "", false
		}
	}
	return o.text + link, true
}

func (o Origin) resource(path string, query url.Values) string {
	if len(query) == 0 {
		return o.text + path
	}
	return o.text + path + "?" + query.Encode()
}
