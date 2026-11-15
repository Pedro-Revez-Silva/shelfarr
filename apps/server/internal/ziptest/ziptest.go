package ziptest

import (
	"bytes"
	"compress/flate"
	"encoding/binary"
	"hash/crc32"
)

const (
	Stored     = 0
	Deflated   = 8
	UTF8Flag   = 0x0800
	Descriptor = 0x0008
	Regular    = uint32(0o100644) << 16
	Directory  = uint32(0o040755)<<16 | 0x10
	UnixMadeBy = 0x031e
)

type Header struct {
	CRC        *uint32
	Compressed *uint32
	Size       *uint32
	Method     *uint16
	Flags      *uint16
	Needed     *uint16
	Name       *string
}

type Entry struct {
	Name         string
	Data         []byte
	Method       uint16
	Flags        *uint16
	Central      Header
	Local        Header
	LocalExtra   []byte
	CentralExtra []byte
	FileComment  []byte
	MadeBy       uint16
	External     *uint32
	Offset       *uint32
	Disk         uint16
	NoDescriptor bool
	LocalSizes   bool
}

type End struct {
	Disk, DirectoryDisk, DiskEntries, Entries *uint16
	DirectorySize, DirectoryOffset            *uint32
	Comment                                   []byte
	BeforeEnd                                 []byte
}

func U16(value uint16) *uint16 { return &value }
func U32(value uint32) *uint32 { return &value }
func Str(value string) *string { return &value }

func Page(name string) Entry {
	return Entry{Name: name, Data: bytes.Repeat([]byte("synthetic image "+name), 3), Method: Deflated}
}

func Raw(name string, data []byte, method uint16) Entry {
	return Entry{Name: name, Data: data, Method: method}
}

func deflate(data []byte) []byte {
	var buffer bytes.Buffer
	writer, _ := flate.NewWriter(&buffer, flate.BestCompression)
	writer.Write(data)
	writer.Close()
	return buffer.Bytes()
}

type resolved struct {
	crc, compressed, size uint32
	method, flags, needed uint16
	name                  string
}

func (h Header) over(base resolved) resolved {
	if h.CRC != nil {
		base.crc = *h.CRC
	}
	if h.Compressed != nil {
		base.compressed = *h.Compressed
	}
	if h.Size != nil {
		base.size = *h.Size
	}
	if h.Method != nil {
		base.method = *h.Method
	}
	if h.Flags != nil {
		base.flags = *h.Flags
	}
	if h.Needed != nil {
		base.needed = *h.Needed
	}
	if h.Name != nil {
		base.name = *h.Name
	}
	return base
}

func asciiOnly(text string) bool {
	for index := 0; index < len(text); index++ {
		if text[index] >= 0x80 {
			return false
		}
	}
	return true
}

func Build(entries []Entry, end End) []byte {
	var body, directory bytes.Buffer
	for _, entry := range entries {
		stored := entry.Data
		if entry.Method == Deflated {
			stored = deflate(entry.Data)
		}
		flags := uint16(0)
		if !asciiOnly(entry.Name) {
			flags = UTF8Flag
		}
		if entry.Flags != nil {
			flags = *entry.Flags
		}
		base := resolved{crc: crc32.ChecksumIEEE(entry.Data), compressed: uint32(len(stored)), size: uint32(len(entry.Data)), method: entry.Method, flags: flags, needed: 20, name: entry.Name}
		central := entry.Central.over(base)
		local := entry.Local.over(base)
		descriptor := central.flags&Descriptor != 0 || local.flags&Descriptor != 0
		if descriptor && !entry.LocalSizes {
			local.crc, local.compressed, local.size = 0, 0, 0
		}
		offset := uint32(body.Len())
		le := binary.LittleEndian
		header := make([]byte, 30)
		le.PutUint32(header, 0x04034b50)
		le.PutUint16(header[4:], local.needed)
		le.PutUint16(header[6:], local.flags)
		le.PutUint16(header[8:], local.method)
		le.PutUint16(header[12:], 0x21)
		le.PutUint32(header[14:], local.crc)
		le.PutUint32(header[18:], local.compressed)
		le.PutUint32(header[22:], local.size)
		le.PutUint16(header[26:], uint16(len(local.name)))
		le.PutUint16(header[28:], uint16(len(entry.LocalExtra)))
		body.Write(header)
		body.WriteString(local.name)
		body.Write(entry.LocalExtra)
		body.Write(stored)
		if descriptor && !entry.NoDescriptor {
			trailer := make([]byte, 12)
			le.PutUint32(trailer, base.crc)
			le.PutUint32(trailer[4:], base.compressed)
			le.PutUint32(trailer[8:], base.size)
			body.Write(trailer)
		}
		madeBy := entry.MadeBy
		if madeBy == 0 {
			madeBy = UnixMadeBy
		}
		external := Regular
		if entry.External != nil {
			external = *entry.External
		}
		recordOffset := offset
		if entry.Offset != nil {
			recordOffset = *entry.Offset
		}
		record := make([]byte, 46)
		le.PutUint32(record, 0x02014b50)
		le.PutUint16(record[4:], madeBy)
		le.PutUint16(record[6:], central.needed)
		le.PutUint16(record[8:], central.flags)
		le.PutUint16(record[10:], central.method)
		le.PutUint16(record[14:], 0x21)
		le.PutUint32(record[16:], central.crc)
		le.PutUint32(record[20:], central.compressed)
		le.PutUint32(record[24:], central.size)
		le.PutUint16(record[28:], uint16(len(central.name)))
		le.PutUint16(record[30:], uint16(len(entry.CentralExtra)))
		le.PutUint16(record[32:], uint16(len(entry.FileComment)))
		le.PutUint16(record[34:], entry.Disk)
		le.PutUint32(record[38:], external)
		le.PutUint32(record[42:], recordOffset)
		directory.Write(record)
		directory.WriteString(central.name)
		directory.Write(entry.CentralExtra)
		directory.Write(entry.FileComment)
	}
	count := uint16(len(entries))
	fields := struct {
		disk, directoryDisk, diskEntries, entries uint16
		size, offset                              uint32
	}{0, 0, count, count, uint32(directory.Len()), uint32(body.Len())}
	if end.Disk != nil {
		fields.disk = *end.Disk
	}
	if end.DirectoryDisk != nil {
		fields.directoryDisk = *end.DirectoryDisk
	}
	if end.DiskEntries != nil {
		fields.diskEntries = *end.DiskEntries
	}
	if end.Entries != nil {
		fields.entries = *end.Entries
	}
	if end.DirectorySize != nil {
		fields.size = *end.DirectorySize
	}
	if end.DirectoryOffset != nil {
		fields.offset = *end.DirectoryOffset
	}
	var archive bytes.Buffer
	archive.Write(body.Bytes())
	archive.Write(directory.Bytes())
	archive.Write(end.BeforeEnd)
	trailer := make([]byte, 22)
	le := binary.LittleEndian
	le.PutUint32(trailer, 0x06054b50)
	le.PutUint16(trailer[4:], fields.disk)
	le.PutUint16(trailer[6:], fields.directoryDisk)
	le.PutUint16(trailer[8:], fields.diskEntries)
	le.PutUint16(trailer[10:], fields.entries)
	le.PutUint32(trailer[12:], fields.size)
	le.PutUint32(trailer[16:], fields.offset)
	le.PutUint16(trailer[20:], uint16(len(end.Comment)))
	archive.Write(trailer)
	archive.Write(end.Comment)
	return archive.Bytes()
}

func Extra(identifier uint16, payload []byte) []byte {
	field := make([]byte, 4, 4+len(payload))
	binary.LittleEndian.PutUint16(field, identifier)
	binary.LittleEndian.PutUint16(field[2:], uint16(len(payload)))
	return append(field, payload...)
}

func Simple(count int) []byte {
	entries := make([]Entry, count)
	for index := range entries {
		entries[index] = Page("p" + string(rune('0'+index/10)) + string(rune('0'+index%10)) + ".png")
	}
	return Build(entries, End{})
}
