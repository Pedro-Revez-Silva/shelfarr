package zipdirectory

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"io"
	"slices"
	"strings"
	"unicode/utf8"

	"golang.org/x/text/unicode/norm"
)

const (
	MaxEntries        = 10_000
	MaxDirectoryBytes = 2 << 20
	MaxNameBytes      = 1024

	eocdBytes       = 22
	centralBytes    = 46
	localBytes      = 30
	maxEOCDComment  = 65_535
	centralSig      = 0x02014b50
	localSig        = 0x04034b50
	allowedFlags    = 0x080e
	dataDescriptor  = 0x0008
	utf8Names       = 0x0800
	descriptorBytes = 12
	Stored          = 0
	Deflated        = 8
)

var (
	eocdSignature  = []byte("PK\x05\x06")
	zip64Locator   = []byte("PK\x06\x07")
	refusedExtraID = []uint16{0x0001, 0x7075, 0x9901}
)

type Invalid struct{ Reason string }

func (e Invalid) Error() string { return e.Reason }

func invalid(reason string) error { return Invalid{reason} }

type Entry struct {
	Name           string
	Flags          uint16
	Method         uint16
	CRC            uint32
	CompressedSize int64
	Size           int64
	Offset         int64
	Directory      bool
	DataOffset     int64
}

type reader struct {
	ctx  context.Context
	file io.ReaderAt
	size int64
}

func (r reader) read(length, offset int64) ([]byte, error) {
	if err := r.ctx.Err(); err != nil {
		return nil, err
	}
	if length == 0 {
		return []byte{}, nil
	}
	if offset < 0 || offset+length > r.size {
		return nil, invalid("This archive is truncated")
	}
	buffer := make([]byte, length)
	count, err := r.file.ReadAt(buffer, offset)
	if count == len(buffer) {
		return buffer, nil
	}
	if err == nil || errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
		return nil, invalid("This archive is truncated")
	}
	return nil, invalid("This archive can't be read")
}

func Entries(ctx context.Context, file io.ReaderAt, size int64) ([]Entry, error) {
	source := reader{ctx: ctx, file: file, size: size}
	directoryOffset, count, directory, err := source.centralDirectory()
	if err != nil {
		return nil, err
	}
	entries, err := parseDirectory(ctx, directory, count)
	if err != nil {
		return nil, err
	}
	return source.checkLocalRecords(entries, directoryOffset)
}

func (r reader) centralDirectory() (directoryOffset int64, count int, directory []byte, err error) {
	if r.size < eocdBytes {
		return 0, 0, nil, invalid("This archive is too small")
	}
	tailLength := min(r.size, eocdBytes+maxEOCDComment)
	tailStart := r.size - tailLength
	tail, err := r.read(tailLength, tailStart)
	if err != nil {
		return 0, 0, nil, err
	}
	var candidates []int
	for index := len(tail) - eocdBytes; index >= 0; index-- {
		if !bytes.Equal(tail[index:index+4], eocdSignature) {
			continue
		}
		comment := int(binary.LittleEndian.Uint16(tail[index+20:]))
		if index+eocdBytes+comment == len(tail) {
			candidates = append(candidates, index)
		}
	}
	if len(candidates) != 1 {
		return 0, 0, nil, invalid("This archive has no unambiguous ZIP directory")
	}
	record := tail[candidates[0] : candidates[0]+eocdBytes]
	disk, directoryDisk := binary.LittleEndian.Uint16(record[4:]), binary.LittleEndian.Uint16(record[6:])
	diskEntries, total := int(binary.LittleEndian.Uint16(record[8:])), int(binary.LittleEndian.Uint16(record[10:]))
	directorySize, offset := int64(binary.LittleEndian.Uint32(record[12:])), int64(binary.LittleEndian.Uint32(record[16:]))
	eocdOffset := tailStart + int64(candidates[0])
	if disk != 0 || directoryDisk != 0 || diskEntries != total || total < 1 || total > MaxEntries ||
		directorySize < int64(centralBytes*total) || directorySize > MaxDirectoryBytes || offset+directorySize != eocdOffset {
		return 0, 0, nil, invalid("This archive's directory is unsupported or too large")
	}
	if eocdOffset >= 20 {
		locator, err := r.read(4, eocdOffset-20)
		if err != nil {
			return 0, 0, nil, err
		}
		if bytes.Equal(locator, zip64Locator) {
			return 0, 0, nil, invalid("ZIP64 archives are not supported")
		}
	}
	directory, err = r.read(directorySize, offset)
	return offset, total, directory, err
}

func parseDirectory(ctx context.Context, directory []byte, count int) ([]Entry, error) {
	entries := make([]Entry, 0, count)
	names := make(map[string]struct{}, count)
	cursor := 0
	for range count {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		if cursor+centralBytes > len(directory) {
			return nil, invalid("This archive's directory is truncated")
		}
		header := directory[cursor : cursor+centralBytes]
		if binary.LittleEndian.Uint32(header) != centralSig {
			return nil, invalid("This archive's directory is damaged")
		}
		madeBy, needed, flags, method := binary.LittleEndian.Uint16(header[4:]), binary.LittleEndian.Uint16(header[6:]), binary.LittleEndian.Uint16(header[8:]), binary.LittleEndian.Uint16(header[10:])
		crc, compressed, size := binary.LittleEndian.Uint32(header[16:]), binary.LittleEndian.Uint32(header[20:]), binary.LittleEndian.Uint32(header[24:])
		nameLength, extraLength, commentLength := int(binary.LittleEndian.Uint16(header[28:])), int(binary.LittleEndian.Uint16(header[30:])), int(binary.LittleEndian.Uint16(header[32:]))
		disk, external, offset := binary.LittleEndian.Uint16(header[34:]), binary.LittleEndian.Uint32(header[38:]), binary.LittleEndian.Uint32(header[42:])
		cursor += centralBytes
		if cursor+nameLength+extraLength+commentLength > len(directory) {
			return nil, invalid("This archive's directory is truncated")
		}
		rawName := directory[cursor : cursor+nameLength]
		extras := directory[cursor+nameLength : cursor+nameLength+extraLength]
		cursor += nameLength + extraLength + commentLength
		supported := flags&^allowedFlags == 0 && (method == Stored || method == Deflated) && needed&0xff <= 45 && disk == 0 &&
			compressed != 0xffff_ffff && size != 0xffff_ffff && offset != 0xffff_ffff && (method == Deflated || compressed == size) && safeExtras(extras)
		if !supported {
			return nil, invalid("This archive uses unsupported ZIP features such as encryption or ZIP64")
		}
		if specialFile(madeBy, external) {
			return nil, invalid("This archive contains a link or special file")
		}
		name, err := entryName(rawName, flags)
		if err != nil {
			return nil, err
		}
		directoryEntry := strings.HasSuffix(name, "/")
		if directoryEntry && size > 0 {
			return nil, invalid("This archive contains a folder with data")
		}
		normalised := norm.NFC.String(name)
		if _, duplicate := names[normalised]; duplicate {
			return nil, invalid("This archive contains duplicate names")
		}
		names[normalised] = struct{}{}
		entries = append(entries, Entry{Name: name, Flags: flags, Method: method, CRC: crc, CompressedSize: int64(compressed), Size: int64(size), Offset: int64(offset), Directory: directoryEntry})
	}
	if cursor != len(directory) {
		return nil, invalid("This archive's directory has unexpected data")
	}
	return entries, nil
}

func entryName(raw []byte, flags uint16) (string, error) {
	if len(raw) < 1 || len(raw) > MaxNameBytes {
		return "", invalid("This archive contains an unsupported name")
	}
	if flags&utf8Names == 0 && !asciiOnly(raw) {
		return "", invalid("This archive's names need UTF-8")
	}
	if !utf8.Valid(raw) {
		return "", invalid("This archive contains a name that isn't valid UTF-8")
	}
	name := string(raw)
	if strings.ContainsFunc(name, unsafeCharacter) || strings.HasPrefix(name, "/") {
		return "", invalid("This archive contains an unsafe name")
	}
	parts := strings.Split(strings.TrimSuffix(name, "/"), "/")
	if slices.ContainsFunc(parts, func(part string) bool { return part == "" || part == "." || part == ".." }) {
		return "", invalid("This archive contains an unsafe name")
	}
	return name, nil
}

func unsafeCharacter(character rune) bool {
	return character == '\\' || character == ':' || character < 0x20 || character == 0x7f
}

func asciiOnly(raw []byte) bool {
	for _, value := range raw {
		if value >= 0x80 {
			return false
		}
	}
	return true
}

func safeExtras(extras []byte) bool {
	cursor := 0
	for cursor < len(extras) {
		if cursor+4 > len(extras) {
			return false
		}
		identifier, length := binary.LittleEndian.Uint16(extras[cursor:]), int(binary.LittleEndian.Uint16(extras[cursor+2:]))
		if slices.Contains(refusedExtraID, identifier) || cursor+4+length > len(extras) {
			return false
		}
		cursor += 4 + length
	}
	return true
}

func specialFile(madeBy uint16, external uint32) bool {
	if madeBy>>8 != 3 {
		return false
	}
	kind := (external >> 16) & 0o170000
	return kind != 0 && kind != 0o100000 && kind != 0o040000
}

func (r reader) checkLocalRecords(entries []Entry, directoryOffset int64) ([]Entry, error) {
	type extent struct{ start, finish int64 }
	extents := make([]extent, 0, len(entries))
	for index := range entries {
		entry := &entries[index]
		header, err := r.read(localBytes, entry.Offset)
		if err != nil {
			return nil, err
		}
		flags, method := binary.LittleEndian.Uint16(header[6:]), binary.LittleEndian.Uint16(header[8:])
		crc, compressed, size := binary.LittleEndian.Uint32(header[14:]), int64(binary.LittleEndian.Uint32(header[18:])), int64(binary.LittleEndian.Uint32(header[22:]))
		nameLength, extraLength := int64(binary.LittleEndian.Uint16(header[26:])), int64(binary.LittleEndian.Uint16(header[28:]))
		descriptor := entry.Flags&dataDescriptor != 0
		matches := binary.LittleEndian.Uint32(header) == localSig && flags == entry.Flags && method == entry.Method && int(nameLength) == len(entry.Name)
		if matches {
			name, err := r.read(nameLength, entry.Offset+localBytes)
			if err != nil {
				return nil, err
			}
			localExtras, err := r.read(extraLength, entry.Offset+localBytes+nameLength)
			if err != nil {
				return nil, err
			}
			agrees := crc == entry.CRC && compressed == entry.CompressedSize && size == entry.Size
			deferred := descriptor && crc == 0 && compressed == 0 && size == 0
			matches = string(name) == entry.Name && safeExtras(localExtras) && (agrees || deferred)
		}
		if !matches {
			return nil, invalid("This archive's entry headers disagree with its directory")
		}
		entry.DataOffset = entry.Offset + localBytes + nameLength + extraLength
		finish := entry.DataOffset + entry.CompressedSize
		if descriptor {
			finish += descriptorBytes
		}
		if finish > directoryOffset {
			return nil, invalid("This archive's entries extend into its directory")
		}
		extents = append(extents, extent{entry.Offset, finish})
	}
	slices.SortFunc(extents, func(left, right extent) int {
		if left.start != right.start {
			return int(left.start - right.start)
		}
		return int(left.finish - right.finish)
	})
	for index := 1; index < len(extents); index++ {
		if extents[index].start < extents[index-1].finish {
			return nil, invalid("This archive's entries overlap")
		}
	}
	return entries, nil
}
