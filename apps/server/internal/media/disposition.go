package media

import (
	"fmt"
	"strings"
)

func transliterate(name string) string {
	var builder strings.Builder
	for _, character := range name {
		switch {
		case character < 0x80:
			builder.WriteRune(character)
		case approximations[character] != "":
			builder.WriteString(approximations[character])
		default:
			builder.WriteByte('?')
		}
	}
	return builder.String()
}

func percentEscape(name string, keep func(byte) bool) string {
	var builder strings.Builder
	for index := 0; index < len(name); index++ {
		if keep(name[index]) {
			builder.WriteByte(name[index])
		} else {
			fmt.Fprintf(&builder, "%%%02X", name[index])
		}
	}
	return builder.String()
}

func alphanumeric(value byte) bool {
	return value >= 'A' && value <= 'Z' || value >= 'a' && value <= 'z' || value >= '0' && value <= '9'
}

func traditionalKept(value byte) bool {
	return alphanumeric(value) || strings.IndexByte(" !#$+.^_`|~-", value) >= 0
}

func extendedKept(value byte) bool {
	return alphanumeric(value) || strings.IndexByte("!#$&+.^_`|~-", value) >= 0
}

func ContentDisposition(disposition, filename string) string {
	return disposition + `; filename="` + percentEscape(transliterate(filename), traditionalKept) + `"; filename*=UTF-8''` + percentEscape(filename, extendedKept)
}
