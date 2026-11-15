package readerformats

import (
	"errors"
	"regexp"
	"slices"
	"strings"
)

const (
	FormatsHeader  = "X-Shelfarr-Reader-Formats"
	FeaturesHeader = "X-Shelfarr-Reader-Features"
)

var (
	supportedFormats  = []string{"cbz", "epub", "pdf"}
	supportedFeatures = []string{"read-along"}
	featureName       = regexp.MustCompile(`^[a-z][a-z0-9-]{0,31}$`)
	graphicFormats    = []string{"cbz", "pdf"}
)

type Invalid struct{ Message string }

func (e Invalid) Error() string { return e.Message }

var ErrUnsupported = errors.New("declared reader capability is not supported by this runtime")

type Formats struct {
	Names    []string
	Declared bool
}

func trim(value string) string {
	return strings.Trim(strings.TrimRight(value, "\x00"), " \t\n\v\f\r")
}

func ParseFormats(value string, present bool) (Formats, error) {
	if !present {
		return Formats{Names: []string{"epub"}}, nil
	}
	if len(value) < 1 || len(value) > 64 {
		return Formats{}, Invalid{"Declare reader formats as a comma-separated list such as epub,pdf,cbz"}
	}
	var names []string
	for _, name := range strings.Split(value, ",") {
		name = trim(name)
		if !slices.Contains(supportedFormats, name) {
			return Formats{}, Invalid{"Unknown or empty reader format; supported formats are " + strings.Join(supportedFormats, ",")}
		}
		if !slices.Contains(names, name) {
			names = append(names, name)
		}
	}
	slices.Sort(names)
	return Formats{Names: names, Declared: true}, nil
}

func (f Formats) Graphic() bool {
	for _, name := range f.Names {
		if slices.Contains(graphicFormats, name) {
			return true
		}
	}
	return false
}

func (f Formats) Default() bool {
	return len(f.Names) == 1 && f.Names[0] == "epub"
}

func (f Formats) Joined() string {
	return strings.Join(f.Names, ",")
}

func (f Formats) RequireSupported() error {
	if f.Graphic() {
		return ErrUnsupported
	}
	return nil
}

func ParseFeatures(value string, present bool) (readAlong bool, err error) {
	if !present {
		return false, nil
	}
	if len(value) < 1 || len(value) > 128 {
		return false, Invalid{"Declare reader features as a comma-separated list such as read-along"}
	}
	var names []string
	for _, name := range strings.Split(value, ",") {
		name = trim(name)
		if !featureName.MatchString(name) {
			return false, Invalid{"Reader feature names are lowercase words joined by hyphens"}
		}
		names = append(names, name)
	}
	for _, name := range names {
		if slices.Contains(supportedFeatures, name) {
			return true, nil
		}
	}
	return false, nil
}
