package webpreview

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"regexp"
	"strconv"
	"strings"
	"unicode"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/consumer"
)

var ErrUnsupported = errors.New("web preview value is not supported")

var coverStyles = []string{"clay", "moss", "slate", "oat", "plum", "stone"}

var fixedLayoutTypes = map[string]bool{"application/pdf": true, "image/jpeg": true, "image/png": true, "image/webp": true}

type Cover struct {
	URL   *string `json:"url"`
	Style string  `json:"style"`
}

type Progress struct {
	AssetID         string   `json:"asset_id"`
	PositionSeconds *float64 `json:"position_seconds"`
	Fraction        *float64 `json:"fraction"`
	Page            *int64   `json:"page"`
	Version         int64    `json:"version"`
	ObservedAt      *string  `json:"observed_at"`
	UpdatedAt       string   `json:"updated_at"`
}

type Summary struct {
	ID            string    `json:"id"`
	Title         string    `json:"title"`
	Author        *string   `json:"author"`
	BookType      string    `json:"book_type"`
	ContentKind   string    `json:"content_kind"`
	FormatLabel   string    `json:"format_label"`
	Availability  string    `json:"availability"`
	Action        string    `json:"action"`
	Cover         Cover     `json:"cover"`
	ReadingStatus string    `json:"reading_status"`
	Progress      *Progress `json:"progress"`
	ProgressLabel string    `json:"progress_label"`
	ReaderURL     string    `json:"reader_url"`
}

type File struct {
	ID        string `json:"id"`
	Filename  string `json:"filename"`
	Format    string `json:"format"`
	MediaType string `json:"media_type"`
	SizeBytes int64  `json:"size_bytes"`
	Position  int    `json:"position"`
	PageCount *int   `json:"page_count"`
}

type Detail struct {
	Summary
	Description string `json:"description"`
	Files       []File `json:"files"`
}

func coverStyle(id string) string {
	value := uint32(0x811c9dc5)
	for index := 0; index < len(id); index++ {
		value = (value ^ uint32(id[index])) * 0x01000193
	}
	return coverStyles[value%6]
}

func formatLabel(publication consumer.Publication) string {
	if publication.BookType == "audiobook" {
		return "Audiobook"
	}
	if publication.ContentKind != nil && *publication.ContentKind == "graphic" {
		return "Comic"
	}
	if len(publication.Assets) > 0 {
		allPDF := true
		for _, asset := range publication.Assets {
			if asset.Format != "pdf" {
				allPDF = false
			}
		}
		if allPDF {
			return "PDF"
		}
	}
	return "Ebook"
}

func object(value any) (map[string]any, bool, error) {
	switch typed := value.(type) {
	case nil:
		return nil, false, nil
	case map[string]any:
		return typed, true, nil
	}
	return nil, false, ErrUnsupported
}

func number(value any) (float64, bool, error) {
	text, ok := value.(json.Number)
	if !ok {
		if value == nil {
			return 0, false, nil
		}
		return 0, false, ErrUnsupported
	}
	parsed, err := strconv.ParseFloat(text.String(), 64)
	if err != nil || math.IsInf(parsed, 0) || math.IsNaN(parsed) {
		return 0, false, ErrUnsupported
	}
	return parsed, true, nil
}

func positiveInteger(value any) *int64 {
	text, ok := value.(json.Number)
	if !ok || strings.ContainsAny(text.String(), ".eE") {
		return nil
	}
	parsed, err := strconv.ParseInt(text.String(), 10, 64)
	if err != nil || parsed <= 0 {
		return nil
	}
	return &parsed
}

type place struct {
	fixed       bool
	page        *int64
	progression *float64
	hasProgress bool
}

func locate(progress *consumer.Progress) (place, error) {
	var found place
	locator, present, err := object(progress.Locator)
	if err != nil || !present {
		return found, err
	}
	if kind, ok := locator["type"].(string); ok {
		found.fixed = fixedLayoutTypes[kind]
	}
	locations, present, err := object(locator["locations"])
	if err != nil || !present {
		return found, err
	}
	found.page = positiveInteger(locations["position"])
	total, ok, err := number(locations["totalProgression"])
	if err != nil {
		return found, err
	}
	if ok {
		found.progression, found.hasProgress = &total, true
	}
	return found, nil
}

func progressBody(progress *consumer.Progress, located place) *Progress {
	if progress == nil {
		return nil
	}
	body := &Progress{AssetID: progress.AssetID, PositionSeconds: progress.PositionSeconds, Version: progress.Version, ObservedAt: progress.ObservedAt, UpdatedAt: progress.UpdatedAt}
	if located.hasProgress {
		clamped := math.Min(math.Max(*located.progression, 0), 1)
		body.Fraction = &clamped
	}
	if located.fixed {
		body.Page = located.page
	}
	return body
}

func clockText(seconds float64) string {
	total := int64(seconds)
	minutes, secs := total/60, total%60
	hours, minutes := minutes/60, minutes%60
	if hours > 0 {
		return fmt.Sprintf("%d:%02d:%02d", hours, minutes, secs)
	}
	return fmt.Sprintf("%d:%02d", minutes, secs)
}

func progressLabel(publication consumer.Publication, located place) string {
	switch {
	case len(publication.Assets) == 0:
		return "Files unavailable"
	case publication.ReadingStatus == "finished":
		return "Finished"
	case publication.ReadingStatus == "unread" && publication.Progress != nil:
		return "Unread · saved place kept"
	case publication.Progress == nil:
		if publication.BookType == "ebook" {
			return "Start reading"
		}
		return "Start listening"
	case !publication.HasAsset(publication.Progress.AssetID):
		return "New edition · start afresh"
	case publication.Progress.PositionSeconds != nil:
		return "Resume at " + clockText(*publication.Progress.PositionSeconds)
	case located.fixed && located.page != nil:
		return "Page " + strconv.FormatInt(*located.page, 10)
	case located.hasProgress:
		return strconv.FormatInt(int64(math.Round(*located.progression*100)), 10) + "% read"
	}
	return "Continue reading"
}

func Project(publication consumer.Publication) (Summary, error) {
	var located place
	if publication.Progress != nil {
		var err error
		if located, err = locate(publication.Progress); err != nil {
			return Summary{}, err
		}
		if located.hasProgress && math.IsInf(*located.progression*100, 0) {
			return Summary{}, ErrUnsupported
		}
	}
	kind := "book"
	if publication.ContentKind != nil {
		kind = *publication.ContentKind
	}
	summary := Summary{
		ID: publication.ID, Title: publication.Title, Author: presence(publication.Author), BookType: publication.BookType, ContentKind: kind,
		FormatLabel: formatLabel(publication), Availability: "available", Action: "read",
		Cover: Cover{URL: publication.CoverURL, Style: coverStyle(publication.ID)}, ReadingStatus: publication.ReadingStatus,
		Progress: progressBody(publication.Progress, located), ProgressLabel: progressLabel(publication, located), ReaderURL: "/read/" + publication.ID,
	}
	if len(publication.Assets) == 0 {
		summary.Availability = "unavailable"
	}
	if publication.BookType == "audiobook" {
		summary.Action = "listen"
	}
	return summary, nil
}

func presence(value *string) *string {
	if value == nil || strings.TrimFunc(*value, unicode.IsSpace) == "" {
		return nil
	}
	return value
}

var (
	runs       = regexp.MustCompile(`[ \t]+`)
	lineEdges  = regexp.MustCompile(` ?\n ?`)
	blankLines = regexp.MustCompile(`\n{3,}`)
)

func PlainText(value string) (string, error) {
	for _, character := range value {
		if character == '<' || character == '>' || character == '&' || character == '\r' || character == 0 || character < 0x20 && character != '\n' && character != '\t' {
			return "", ErrUnsupported
		}
	}
	text := runs.ReplaceAllString(value, " ")
	text = lineEdges.ReplaceAllString(text, "\n")
	text = blankLines.ReplaceAllString(text, "\n\n")
	return strings.Trim(text, " \t\n\v\f\r"), nil
}

func ProjectDetail(publication consumer.Publication) (Detail, error) {
	summary, err := Project(publication)
	if err != nil {
		return Detail{}, err
	}
	description, err := PlainText(publication.Description)
	if err != nil {
		return Detail{}, err
	}
	files := make([]File, 0, len(publication.Assets))
	for _, asset := range publication.Assets {
		files = append(files, File{ID: asset.ID, Filename: asset.Filename, Format: asset.Format, MediaType: asset.MediaType, SizeBytes: asset.SizeBytes, Position: asset.Position})
	}
	return Detail{Summary: summary, Description: description, Files: files}, nil
}
