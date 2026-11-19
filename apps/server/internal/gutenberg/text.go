package gutenberg

import (
	"strings"
	"unicode"
)

var languageNames = map[string]string{
	"en": "English", "nl": "Dutch", "de": "German", "fr": "French", "es": "Spanish", "it": "Italian",
	"pt": "Portuguese", "pt-BR": "Portuguese (Brazil)", "ru": "Russian", "ja": "Japanese", "ko": "Korean",
	"zh": "Chinese", "pl": "Polish", "sv": "Swedish", "da": "Danish", "no": "Norwegian", "fi": "Finnish",
	"tr": "Turkish", "ar": "Arabic", "he": "Hebrew", "hi": "Hindi", "th": "Thai", "vi": "Vietnamese",
	"cs": "Czech", "hu": "Hungarian", "ro": "Romanian", "bg": "Bulgarian", "uk": "Ukrainian", "el": "Greek",
}

func RubyStrip(text string) string {
	text = strings.TrimLeft(text, "\t\n\v\f\r ")
	return strings.TrimRight(text, "\t\n\v\f\r \x00")
}

func RubyBlank(text string) bool {
	return strings.TrimFunc(text, unicode.IsSpace) == ""
}

func languageDisplayName(code string) string {
	if name, known := languageNames[code]; known {
		return name
	}
	return code
}

func resultTitle(candidate Candidate) string {
	var parts []string
	if !RubyBlank(candidate.Title) {
		parts = append(parts, candidate.Title)
	}
	if !RubyBlank(candidate.Author) {
		parts = append(parts, "- "+candidate.Author)
	}
	parts = append(parts, "["+strings.ToUpper(candidate.FileType)+"]")
	if name := languageDisplayName(candidate.Language); !RubyBlank(name) {
		parts = append(parts, "["+name+"]")
	}
	return strings.Join(parts, " ")
}
