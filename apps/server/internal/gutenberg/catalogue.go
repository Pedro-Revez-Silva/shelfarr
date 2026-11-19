package gutenberg

import (
	"regexp"
	"strings"
)

const (
	epubType        = "application/epub+zip"
	acquisitionRel  = "opds-spec.org/acquisition"
	maxBookIDDigits = 12
)

var (
	ebooksID      = regexp.MustCompile(`ebooks/([0-9]+)`)
	urnID         = regexp.MustCompile(`urn:gutenberg:([0-9]+)`)
	epub3Title    = regexp.MustCompile(`(?i)EPUB3`)
	imagesTitle   = regexp.MustCompile(`(?i)images`)
	noImagesTitle = regexp.MustCompile(`(?i)no images`)
	kindleTitle   = regexp.MustCompile(`(?i)\AKindle\z`)
)

type Candidate struct {
	ID          string
	Title       string
	Author      string
	Language    string
	FileType    string
	DownloadURL string
	InfoURL     string
}

func (c Candidate) GUID() string { return "gutenberg:" + c.ID }

func (c Candidate) ResultTitle() string { return resultTitle(c) }

type listing struct {
	id string
}

func extractBookID(value string) (string, bool) {
	match := ebooksID.FindStringSubmatch(value)
	if match == nil {
		match = urnID.FindStringSubmatch(value)
	}
	if match == nil {
		return "", true
	}
	return match[1], len(match[1]) <= maxBookIDDigits
}

func parseListings(body []byte) ([]listing, bool, error) {
	root, err := parseDocument(body)
	if err != nil {
		return nil, false, err
	}
	found, err := entries(root)
	if err != nil {
		return nil, false, err
	}
	seen := map[string]bool{}
	var listings []listing
	for _, entry := range found {
		reference := ""
		for _, link := range entry.children {
			if href, present := link.attrs["href"]; present && link.name == "link" && link.attrs["rel"] == "subsection" {
				reference = href
				break
			}
		}
		if RubyBlank(reference) {
			reference, _ = entry.childText("id")
		}
		id, bounded := extractBookID(reference)
		if !bounded {
			return nil, false, errMalformed
		}
		if id == "" || seen[id] {
			continue
		}
		seen[id] = true
		listings = append(listings, listing{id: id})
	}
	return listings, hasNextPage(root), nil
}

type format struct {
	fileType string
	href     string
	score    int
}

type detail struct {
	candidate *Candidate
	withheld  bool
}

func parseDetail(body []byte, fallbackID, requestedLanguage string, origin Origin) (detail, error) {
	root, err := parseDocument(body)
	if err != nil {
		return detail{}, err
	}
	found, err := entries(root)
	if err != nil {
		return detail{}, err
	}
	var bestEntry *element
	var best format
	var bestLanguage string
	for _, entry := range found {
		language := ""
		if text, present := entry.childText("language"); present {
			language = strings.ToLower(RubyStrip(text))
			if RubyBlank(language) {
				language = ""
			}
		}
		if !RubyBlank(requestedLanguage) && language != "" && language != requestedLanguage {
			continue
		}
		preferred, ok := preferredFormat(entry)
		if !ok {
			continue
		}
		if bestEntry == nil || preferred.score > best.score {
			bestEntry, best, bestLanguage = entry, preferred, language
		}
	}
	if bestEntry == nil {
		return detail{}, nil
	}
	idText, _ := bestEntry.childText("id")
	id, bounded := extractBookID(idText)
	if !bounded {
		return detail{}, errMalformed
	}
	if id == "" {
		id = fallbackID
	}
	if best.fileType != "epub" {
		return detail{withheld: true}, nil
	}
	download, authorized := origin.Authorize(best.href)
	if !authorized {
		return detail{withheld: true}, nil
	}
	title, _ := bestEntry.childText("title")
	author, _ := bestEntry.childText("author", "name")
	author = RubyStrip(author)
	if RubyBlank(author) {
		author = ""
	}
	return detail{candidate: &Candidate{
		ID:          id,
		Title:       RubyStrip(title),
		Author:      author,
		Language:    bestLanguage,
		FileType:    "epub",
		DownloadURL: download,
		InfoURL:     origin.text + "/ebooks/" + id,
	}}, nil
}

func preferredFormat(entry *element) (format, bool) {
	var best format
	found := false
	for _, link := range entry.children {
		if link.name != "link" || !strings.Contains(link.attrs["rel"], acquisitionRel) {
			continue
		}
		candidate, ok := linkFormat(link)
		if ok && (!found || candidate.score > best.score) {
			best, found = candidate, true
		}
	}
	return best, found
}

func linkFormat(link *element) (format, bool) {
	mime, _, _ := strings.Cut(link.attrs["type"], ";")
	href := RubyStrip(link.attrs["href"])
	if RubyBlank(href) {
		return format{}, false
	}
	var candidate format
	switch mime {
	case epubType:
		candidate = format{fileType: "epub", score: 300}
	case "application/x-mobipocket-ebook":
		candidate = format{fileType: "mobi", score: 200}
	case "application/pdf":
		candidate = format{fileType: "pdf", score: 100}
	default:
		return format{}, false
	}
	title := link.attrs["title"]
	if epub3Title.MatchString(title) {
		candidate.score += 40
	}
	if imagesTitle.MatchString(title) && !noImagesTitle.MatchString(title) {
		candidate.score += 30
	}
	if kindleTitle.MatchString(title) {
		candidate.score += 10
	}
	candidate.href = href
	return candidate, true
}
