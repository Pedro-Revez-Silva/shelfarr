package admission

import (
	"errors"
	"regexp"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/strictjson"
)

const (
	MaxBodyBytes     = 64 << 10
	textLimit        = 500
	languageLimit    = 16
	maxSourceWorkIDs = 20
	earliestYear     = 1
	latestYear       = 3000
)

var (
	ErrInvalid     = errors.New("invalid_request")
	ErrUnsupported = errors.New("unsupported_request")

	railsWorkID       = regexp.MustCompile(`\A[a-z_]{2,32}:[^ \t\r\n\f\v]+\z`)
	openLibraryWorkID = regexp.MustCompile(`\Aopenlibrary:(OL[1-9][0-9]{0,11}W)\z`)
	plainHTTPSCover   = regexp.MustCompile(`\Ahttps://[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?:/(?:[A-Za-z0-9\-._~!$&'()*+,;=:@/]|%[0-9A-Fa-f]{2})*)?(?:\?(?:[A-Za-z0-9\-._~!$&'()*+,;=:@/?]|%[0-9A-Fa-f]{2})*)?\z`)
)

type Submission struct {
	OpenLibraryWorkID string
	Title             string
	Author            *string
	CoverURL          *string
	Year              *int64
	Language          *string
}

func ParseSubmission(body []byte) (Submission, error) {
	if len(body) > MaxBodyBytes {
		return Submission{}, ErrInvalid
	}
	document, err := strictjson.Parse(body)
	if err != nil || document.Kind != strictjson.Object {
		return Submission{}, ErrInvalid
	}
	workID, ok := railsWorkIDMember(document, "work_id")
	if !ok {
		return Submission{}, ErrInvalid
	}
	bookType, _ := document.Member("book_type")
	if bookType.Kind != strictjson.String || (bookType.Text != "ebook" && bookType.Text != "audiobook") {
		return Submission{}, ErrInvalid
	}
	title, ok := requiredTitle(document)
	if !ok {
		return Submission{}, ErrInvalid
	}
	sources, ok := sourceWorkIDs(document)
	if !ok {
		return Submission{}, ErrInvalid
	}
	author, authorOK := optionalText(document, "author", textLimit)
	cover, coverOK := optionalText(document, "cover_url", textLimit)
	language, languageOK := optionalText(document, "language", languageLimit)
	year, yearOK := optionalYear(document)
	if !authorOK || !coverOK || !languageOK || !yearOK {
		return Submission{}, ErrInvalid
	}
	match := openLibraryWorkID.FindStringSubmatch(workID)
	if match == nil || bookType.Text != "ebook" || sources > 0 {
		return Submission{}, ErrUnsupported
	}
	return Submission{
		OpenLibraryWorkID: match[1],
		Title:             title,
		Author:            author,
		CoverURL:          safeCover(cover),
		Year:              year,
		Language:          language,
	}, nil
}

func railsWorkIDMember(document strictjson.Value, key string) (string, bool) {
	value, _ := document.Member(key)
	if value.Kind != strictjson.String {
		return "", false
	}
	return value.Text, isRailsWorkID(value.Text)
}

func isRailsWorkID(text string) bool {
	if !railsWorkID.MatchString(text) {
		return false
	}
	_, identifier, _ := strings.Cut(text, ":")
	return utf8.RuneCountInString(identifier) <= 160
}

func requiredTitle(document strictjson.Value) (string, bool) {
	value, _ := document.Member("title")
	if value.Kind != strictjson.String || utf8.RuneCountInString(value.Text) > textLimit || strings.ContainsRune(value.Text, 0) {
		return "", false
	}
	stripped := rubyStrip(value.Text)
	return stripped, !rubyBlank(stripped)
}

func sourceWorkIDs(document strictjson.Value) (int, bool) {
	value, present := document.Member("source_work_ids")
	if !present || value.Kind == strictjson.Null {
		return 0, true
	}
	if value.Kind != strictjson.Array || len(value.Items) > maxSourceWorkIDs {
		return 0, false
	}
	for _, item := range value.Items {
		if item.Kind != strictjson.String || !isRailsWorkID(item.Text) {
			return 0, false
		}
	}
	return len(value.Items), true
}

func optionalText(document strictjson.Value, key string, limit int) (*string, bool) {
	value, present := document.Member(key)
	if !present || value.Kind == strictjson.Null {
		return nil, true
	}
	if value.Kind != strictjson.String || utf8.RuneCountInString(value.Text) > limit || strings.ContainsRune(value.Text, 0) {
		return nil, false
	}
	stripped := rubyStrip(value.Text)
	if rubyBlank(stripped) {
		return nil, true
	}
	return &stripped, true
}

func optionalYear(document strictjson.Value) (*int64, bool) {
	value, present := document.Member("year")
	if !present || value.Kind == strictjson.Null {
		return nil, true
	}
	if value.Kind != strictjson.Integer {
		return nil, false
	}
	year, err := strconv.ParseInt(value.Text, 10, 64)
	if err != nil || year < earliestYear || year > latestYear {
		return nil, false
	}
	return &year, true
}

func safeCover(value *string) *string {
	if value == nil || !plainHTTPSCover.MatchString(*value) {
		return nil
	}
	return value
}

func rubyStrip(text string) string {
	return strings.Trim(text, "\t\n\v\f\r ")
}

func rubyBlank(text string) bool {
	return strings.TrimFunc(text, unicode.IsSpace) == ""
}
