//go:build e2e

package httpruntime

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type edit struct {
	old string
	new string
}

type mutant struct {
	name     string
	file     string
	edit     edit
	scenario string
	unit     string
	unitRun  string
}

var differential = "TestDifferentialAgainstRails"

const transferUnitTests = "Grant|Transfer|Minted|Minting|OnlyGet|Rechecks|RemovedAndReplaced|OnlyTheLiteral"

var mutants = []mutant{
	{name: "auth: a revoked credential still authenticates", file: "internal/live/queries.go", edit: edit{"AND revoked_at IS NULL AND (expires_at", "AND (1 OR revoked_at IS NULL) AND (expires_at"}, unit: "./internal/live/", scenario: differential},
	{name: "auth: an expired credential still authenticates", file: "internal/live/queries.go", edit: edit{"(expires_at IS NULL OR expires_at > ?)", "(1 OR expires_at > ?)"}, unit: "./internal/live/", scenario: differential},
	{name: "auth: a deleted account still authenticates", file: "internal/bearer/bearer.go", edit: edit{"if user != nil && user.Deleted {", "if false {"}, unit: "./internal/bearer/", scenario: differential},
	{name: "auth: contention during adoption is reported as an anonymous request", file: "internal/bearer/bearer.go", edit: edit{"if err != nil || !adopted {\n\t\treturn nil, err\n\t}", "if err != nil || !adopted {\n\t\treturn nil, nil\n\t}"}, unit: "./internal/bearer/"},
	{name: "auth: contention while recording use is reported as an anonymous request", file: "internal/bearer/bearer.go", edit: edit{"if err := a.DB.TouchToken(ctx, token.ID, a.Now()); err != nil {\n\t\treturn nil, err\n\t}", "if err := a.DB.TouchToken(ctx, token.ID, a.Now()); err != nil {\n\t\treturn nil, nil\n\t}"}, unit: "./internal/bearer/", scenario: "TestABusyDatabase"},
	{name: "adoption: the previous credential is not retired", file: "internal/live/tokens.go", edit: edit{"SET revoked_at = ?, updated_at = ? WHERE id = ? AND revoked_at IS NULL`", "SET updated_at = ?, revoked_at = NULL WHERE ? IS NOT NULL AND id = ?`"}, unit: "./internal/live/", scenario: differential},
	{name: "adoption: another account's credential may be adopted", file: "internal/live/tokens.go", edit: edit{"previous.user != token.UserID", "false"}, unit: "./internal/live/", scenario: differential},
	{name: "scopes: library:read is not required", file: "internal/gohttp/app.go", edit: edit{`if required != "" && !principal.HasScope(required) {`, "if false {"}, scenario: differential},
	{name: "cursor: the account is not part of the binding", file: "internal/catalogue/catalogue.go", edit: edit{"parts := []string{strconv.FormatInt(userID, 10), query,", `parts := []string{"0", query,`}, unit: "./internal/catalogue/", scenario: differential},
	{name: "cursor: the signature is not verified", file: "internal/railsmsg/railsmsg.go", edit: edit{"if !hmac.Equal([]byte(digest), []byte(v.sign(text))) {", "if false && !hmac.Equal([]byte(digest), []byte(v.sign(text))) {"}, unit: "./internal/railsmsg/"},
	{name: "path: opens follow symbolic links", file: "internal/media/open_linux.go", edit: edit{"unix.RESOLVE_BENEATH | unix.RESOLVE_NO_SYMLINKS | unix.RESOLVE_NO_MAGICLINKS,", "unix.RESOLVE_BENEATH,"}, unit: "./internal/media/"},
	{name: "path: dotted segments reach the asset routes", file: "internal/gohttp/routes.go", edit: edit{`!strings.ContainsAny(segment, ".?")`, `!strings.ContainsAny(segment, "?")`}, unit: "./internal/gohttp/", scenario: differential},
	{name: "identity: the opened file is not re-checked against the asset id", file: "internal/gohttp/handlers.go", edit: edit{"if current != asset.ID {", "if false && current != asset.ID {"}, unit: "./internal/gohttp/"},
	{name: "roots: a database root outside the configured roots is accepted", file: "internal/gohttp/handlers.go", edit: edit{"if !withinAny(root, a.explicitRoots) {", "if false && !withinAny(root, a.explicitRoots) {"}, scenario: "TestADatabaseRoot"},
	{name: "layout: reference imports are reported as a generic error", file: "internal/gohttp/respond.go", edit: edit{"errors.Is(err, library.ErrReference), errors.Is(err, library.ErrUnsupportedPath)", "errors.Is(err, library.ErrUnsupportedPath)"}, scenario: "TestMissingDeletedReplaced"},
	{name: "range: a suffix range reads from the start", file: "internal/media/ranges.go", edit: edit{"return Span{First: max(size-suffix, 0), Last: size - 1}, true", "return Span{First: 0, Last: min(suffix, size) - 1}, true"}, unit: "./internal/media/", scenario: differential},
	{name: "range: HEAD honours a range", file: "internal/media/serve.go", edit: edit{"if r.Method != http.MethodHead && strings.TrimSpace(rangeHeader) != \"\" {", "if strings.TrimSpace(rangeHeader) != \"\" {"}, scenario: differential},
	{name: "conditional: If-None-Match is ignored", file: "internal/media/serve.go", edit: edit{"if etagMatches(strings.Join(", "if false && etagMatches(strings.Join("}, scenario: differential},
	{name: "capacity: media streams are not bounded", file: "internal/gohttp/app.go", edit: edit{"streams:       make(chan struct{}, config.MaxMediaStreams),", "streams:       make(chan struct{}, config.MaxMediaStreams*1000),"}, scenario: "TestStalledMediaClients|TestAClientThatDisconnects"},
	{name: "startup: an unknown schema revision is accepted", file: "internal/live/live.go", edit: edit{"if !contains(SupportedRevisions, revision) {", "if false && !contains(SupportedRevisions, revision) {"}, unit: "./internal/live/", scenario: "TestStartupRefuses"},
	{name: "startup: a missing secret key base is replaced by a default", file: "internal/gohttp/secret.go", edit: edit{"return \"\", ErrSecretMissing", "return \"development-secret-key-base-development-secret-key-base\", nil"}, unit: "./internal/gohttp/", scenario: "TestStartupRefuses"},
	{name: "wal: reads ignore the write-ahead log", file: "internal/live/live.go", edit: edit{`query.Set("mode", "rw")`, "query.Set(\"mode\", \"ro\")\n\tquery.Set(\"immutable\", \"1\")"}, unit: "./internal/live/", scenario: "TestLiveWal"},
	{name: "catalogue: a whitespace status filters every book away", file: "internal/catalogue/catalogue.go", edit: edit{"if !params.Status.Blank() {\n\t\tselection.Status = status", "if true {\n\t\tselection.Status = status"}, unit: "./internal/catalogue/"},
	{name: "capacity: a client that never reads a metadata response holds its slot", file: "internal/gohttp/run.go", edit: edit{"WriteTimeout:      config.RequestTimeout + responseGrace,", "WriteTimeout:      0,"}, unit: "./internal/gohttp/"},
	{name: "progress: a read-only credential may write", file: "internal/gohttp/app.go", edit: edit{"if found.kind == routeReadingStatus || found.kind == routeProgress && method == http.MethodPut {", "if found.kind == routeReadingStatus {"}, unit: "./internal/gohttp/", scenario: differential},
	{name: "progress: the expected version is ignored", file: "internal/live/progress.go", edit: edit{"if current.Version != write.ExpectedVersion {", "if false && current.Version != write.ExpectedVersion {"}, unit: "./internal/live/", scenario: differential},
	{name: "progress: a first write may claim a later version", file: "internal/live/progress.go", edit: edit{"if write.ExpectedVersion != 0 {", "if false {"}, unit: "./internal/live/", scenario: differential},
	{name: "progress: a reused mutation id may carry different data", file: "internal/live/progress.go", edit: edit{"if current.ClientMutationID == write.MutationID {", "if false && current.ClientMutationID == write.MutationID {"}, unit: "./internal/live/", scenario: differential},
	{name: "progress: a retry ignores the original activity time", file: "internal/live/progress.go", edit: edit{"return sameObservation(current, write)\n}", "return true, nil\n}"}, unit: "./internal/live/", scenario: differential},
	{name: "progress: earlier activity replaces later activity", file: "internal/live/progress.go", edit: edit{"if !write.Resolve {", "if false && !write.Resolve {"}, unit: "./internal/live/", scenario: differential},
	{name: "progress: a resolution bypasses the version", file: "internal/live/progress.go", edit: edit{"if current.Version != write.ExpectedVersion {", "if !write.Resolve && current.Version != write.ExpectedVersion {"}, unit: "./internal/live/", scenario: differential},
	{name: "progress: equal times at the same place conflict", file: "internal/live/progress.go", edit: edit{"\treturn samePlace(current, write)\n}\n\nfunc (d *DB) SetReadingStatus", "\treturn false, nil\n}\n\nfunc (d *DB) SetReadingStatus"}, unit: "./internal/live/", scenario: differential},
	{name: "progress: an unknown activity time becomes the upload time", file: "internal/live/progress.go", edit: edit{"func observedText(moment *time.Time) any {\n\tif moment == nil {\n\t\treturn nil\n\t}", "func observedText(moment *time.Time) any {\n\tif moment == nil {\n\t\treturn TimestampText(time.Now())\n\t}"}, unit: "./internal/live/", scenario: differential},
	{name: "progress: an update skips a version", file: "internal/live/progress.go", edit: edit{"nullableFloat(write.PositionSeconds), current.Version+1, write.MutationID", "nullableFloat(write.PositionSeconds), current.Version+2, write.MutationID"}, unit: "./internal/live/", scenario: differential},
	{name: "progress: the write time is read before the lock is held", file: "internal/live/progress.go", edit: edit{"clock func() time.Time) (ProgressResult, error) {\n\ttx, err := d.write.BeginTx(ctx, nil)", "clock func() time.Time) (ProgressResult, error) {\n\tearly := clock()\n\tclock = func() time.Time { return early }\n\ttx, err := d.write.BeginTx(ctx, nil)"}, unit: "./internal/live/"},
	{name: "progress: another account's place is read under the lock", file: "internal/live/progress.go", edit: edit{"FROM consumer_progresses WHERE user_id = ? AND book_id = ? ORDER BY id LIMIT 1`, userID, bookID).", "FROM consumer_progresses WHERE (user_id = ? OR 1) AND book_id = ? ORDER BY id LIMIT 1`, userID, bookID)."}, unit: "./internal/live/", scenario: differential},
	{name: "progress: locators are compared as text", file: "internal/live/progress.go", edit: edit{"return strictjson.Equal(stored, *write.Locator), nil", "return stored.Encode() == write.Locator.Encode(), nil"}, unit: "./internal/live/", scenario: differential},
	{name: "status: repeating a status moves its time", file: "internal/live/progress.go", edit: edit{"case err == nil && existing != status:", "case err == nil:"}, unit: "./internal/live/", scenario: differential},
	{name: "status: choosing a status discards the saved place", file: "internal/live/progress.go", edit: edit{"\tdefer tx.Rollback()\n\tif err := fault.Hit(ctx, \"status.locked\"); err != nil {", "\tdefer tx.Rollback()\n\ttx.ExecContext(ctx, `DELETE FROM consumer_progresses WHERE user_id = ? AND book_id = ?`, userID, bookID)\n\tif err := fault.Hit(ctx, \"status.locked\"); err != nil {"}, unit: "./internal/live/", scenario: differential},
	{name: "progress: activity times far in the future are accepted", file: "internal/checkpoint/checkpoint.go", edit: edit{"if parsed.After(now.Add(futureTolerance)) {", "if false {"}, unit: "./internal/checkpoint/", scenario: differential},
	{name: "progress: parent directory segments are accepted", file: "internal/checkpoint/checkpoint.go", edit: edit{`if segment == ".." {`, `if segment == ".." && false {`}, unit: "./internal/checkpoint/", scenario: differential},
	{name: "progress: the expected version range is one too wide", file: "internal/checkpoint/checkpoint.go", edit: edit{"number.Cmp(big.NewInt(MaxVersion)) > 0", "number.Cmp(big.NewInt(MaxVersion+1)) > 0"}, unit: "./internal/checkpoint/", scenario: differential},
	{name: "progress: request bodies are not bounded", file: "internal/gohttp/progress.go", edit: edit{"io.ReadAll(http.MaxBytesReader(w, r.Body, limit))", "io.ReadAll(r.Body)"}, unit: "./internal/gohttp/", scenario: "TestWriteBodies"},
	{name: "progress: a stalled body is never timed out", file: "internal/gohttp/progress.go", edit: edit{"control.SetReadDeadline(time.Now().Add(a.config.BodyTimeout))", "control.SetReadDeadline(time.Now().Add(a.config.BodyTimeout * 10000))"}, scenario: "TestWriteBodies"},
	{name: "progress: any content type is parsed", file: "internal/gohttp/progress.go", edit: edit{`if err != nil || mediaType != "application/json" {`, "if _, _ = mediaType, err; false {"}, unit: "./internal/gohttp/", scenario: differential},
	{name: "progress: a conflict is reported as success", file: "internal/gohttp/progress.go", edit: edit{`a.respondStored(w, result, http.StatusConflict, "progress_conflict", saved.Progress)`, `a.respondStored(w, result, http.StatusOK, "", saved.Progress)`}, unit: "./internal/gohttp/", scenario: differential},
	{name: "progress: a malformed body is reported as a validation error", file: "internal/gohttp/progress.go", edit: edit{`problem(w, result, http.StatusBadRequest, "invalid_json")`, `problem(w, result, http.StatusUnprocessableEntity, "invalid_json")`}, unit: "./internal/gohttp/", scenario: differential},
	{name: "formats: fixed-layout assets are sent inline", file: "internal/gohttp/handlers.go", edit: edit{`served.Disposition, served.ContentSecurityPolicy = "attachment", documentPolicy`, `served.Disposition, served.ContentSecurityPolicy = "inline", documentPolicy`}, unit: "./internal/gohttp/", scenario: differential},
	{name: "formats: fixed-layout assets carry no document policy", file: "internal/gohttp/handlers.go", edit: edit{`served.Disposition, served.ContentSecurityPolicy = "attachment", documentPolicy`, `served.Disposition, served.ContentSecurityPolicy = "attachment", ""`}, unit: "./internal/gohttp/", scenario: differential},
	{name: "formats: comic records are hidden from clients that declared a fixed-layout format", file: "internal/catalogue/catalogue.go", edit: edit{"if graphic {\n\t\treading = append(reading, store.BookTypeComicbook)", "if false {\n\t\treading = append(reading, store.BookTypeComicbook)"}, unit: "./internal/gohttp/", scenario: differential},
	{name: "formats: continue lists comic records for legacy clients", file: "internal/gohttp/handlers.go", edit: edit{`catalogue.ReadingTypes("", formats.Graphic()), continueScan)`, `catalogue.ReadingTypes("", true), continueScan)`}, unit: "./internal/gohttp/", scenario: differential},
	{name: "formats: a publication shows comic records to legacy clients", file: "internal/gohttp/handlers.go", edit: edit{`book, ok := a.lookupBook(w, r, rawID, catalogue.ReadingTypes("", formats.Graphic()), result)`, `book, ok := a.lookupBook(w, r, rawID, allBookTypes, result)`}, unit: "./internal/gohttp/", scenario: differential},
	{name: "formats: the selection is not part of the cursor identity", file: "internal/catalogue/catalogue.go", edit: edit{"if !formats.Default() {\n\t\tparts = append(parts, formats.Joined())", "if false {\n\t\tparts = append(parts, formats.Joined())"}, unit: "./internal/gohttp/", scenario: differential},
	{name: "formats: a selection is not sorted before it binds cursors", file: "internal/readerformats/readerformats.go", edit: edit{"\tslices.Sort(names)\n", ""}, unit: "./internal/readerformats/", scenario: differential},
	{name: "formats: the selection does not reach the listing", file: "internal/gohttp/handlers.go", edit: edit{"view := consumer.NewViewFor(roots, formats.Names, progress, states, formats.Declared)", "view := consumer.NewViewFor(roots, nil, progress, states, formats.Declared)"}, unit: "./internal/gohttp/", scenario: differential},
	{name: "assets: a PDF without its header is offered", file: "internal/library/assets.go", edit: edit{"if !pdfHeader.Match(header[:count]) {", "if count < 0 {"}, unit: "./internal/library/", scenario: differential},
	{name: "assets: the PDF header window is wider than a kibibyte", file: "internal/library/assets.go", edit: edit{"pdfWindow    = 1024", "pdfWindow    = 2048"}, unit: "./internal/library/", scenario: differential},
	{name: "assets: a CBZ that fails its page check is offered", file: "internal/library/assets.go", edit: edit{"if errors.As(err, &invalid) {\n\t\treturn 0, errNotOffered\n\t}\n\tif err != nil {\n\t\treturn 0, err\n\t}\n\tinspected.remember", "if errors.As(err, &invalid) {\n\t\treturn 0, nil\n\t}\n\tif err != nil {\n\t\treturn 0, err\n\t}\n\tinspected.remember"}, unit: "./internal/library/", scenario: differential},
	{name: "assets: a file over its size limit is offered", file: "internal/library/assets.go", edit: edit{"if stat.Size > limit {", "if stat.Size > limit*2 {"}, unit: "./internal/library/"},
	{name: "assets: the size limit excludes its own boundary", file: "internal/library/assets.go", edit: edit{"if stat.Size > limit {", "if stat.Size >= limit {"}, unit: "./internal/library/"},
	{name: "assets: a replaced file is inspected under the old identity", file: "internal/library/assets.go", edit: edit{"if err != nil || !os.SameFile(opened, expected) {", "if err != nil || opened == nil && expected == nil {"}, unit: "./internal/library/"},
	{name: "assets: finding an asset does not inspect it", file: "internal/library/assets.go", edit: edit{"inspected, err := l.asset(ctx, book, bookPath, candidate, true)", "inspected, err := l.asset(ctx, book, bookPath, candidate, false)"}, unit: "./internal/library/", scenario: differential},
	{name: "assets: a scan ignores cancellation", file: "internal/library/assets.go", edit: edit{"func (l Lister) asset(ctx context.Context, book store.Book, bookPath, path string, inspect bool) (Asset, error) {\n\tif err := ctx.Err(); err != nil {\n\t\treturn Asset{}, err\n\t}", "func (l Lister) asset(ctx context.Context, book store.Book, bookPath, path string, inspect bool) (Asset, error) {"}, unit: "./internal/library/"},
	{name: "assets: a folder scan ignores cancellation", file: "internal/library/assets.go", edit: edit{"\tfor len(pending) > 0 {\n\t\tif err := ctx.Err(); err != nil {\n\t\t\treturn nil, err\n\t\t}", "\tfor len(pending) > 0 {"}, unit: "./internal/library/"},
	{name: "reading order: names are ordered case sensitively", file: "internal/naturalorder/naturalorder.go", edit: edit{"lowered := Downcase(name)", "lowered := name"}, unit: "./internal/naturalorder/", scenario: differential},
	{name: "reading order: a final sigma is lowered by context", file: "internal/naturalorder/naturalorder.go", edit: edit{"cases.HandleFinalSigma(false)", "cases.HandleFinalSigma(true)"}, unit: "./internal/naturalorder/", scenario: differential},
	{name: "reading order: letters Ruby does not lower are lowered", file: "internal/naturalorder/naturalorder.go", edit: edit{"if !unicode.Is(unlowered, character) {", "if true {"}, unit: "./internal/naturalorder/", scenario: differential},
	{name: "reading order: numbers are compared as text", file: "internal/naturalorder/naturalorder.go", edit: edit{"if left[index].number && right[index].number {", "if false {"}, unit: "./internal/naturalorder/", scenario: differential},
	{name: "reading order: hidden entries are pages", file: "internal/comic/comic.go", edit: edit{"if entry.Directory || hidden(entry.Name) {", "if entry.Directory {"}, unit: "./internal/comic/", scenario: differential},
	{name: "reading order: positions start at zero", file: "internal/comic/comic.go", edit: edit{"Position: index + 1,", "Position: index,"}, unit: "./internal/comic/", scenario: differential},
	{name: "reading order: ties are not broken by the exact name", file: "internal/comic/comic.go", edit: edit{"return strings.Compare(left.entry.Name, right.entry.Name)", "return 0"}, unit: "./internal/comic/", scenario: differential},
	{name: "reading order: hrefs are not escaped", file: "internal/comic/comic.go", edit: edit{"href := escape(entry.Name)", "href := entry.Name"}, unit: "./internal/comic/", scenario: differential},
	{name: "reading order: the 2 GiB total is not enforced", file: "internal/comic/comic.go", edit: edit{"if total > MaxTotalBytes {", "if false {"}, unit: "./internal/comic/"},
	{name: "reading order: a page over 32 MiB is accepted", file: "internal/comic/comic.go", edit: edit{"if entry.Size < 1 || entry.Size > MaxImageBytes {", "if entry.Size < 1 {"}, unit: "./internal/comic/"},
	{name: "reading order: a page over the compressed limit is accepted", file: "internal/comic/comic.go", edit: edit{"if entry.CompressedSize < 1 || entry.CompressedSize > MaxCompressedImageBytes {", "if entry.CompressedSize < 1 {"}, unit: "./internal/comic/"},
	{name: "reading order: an archive without pages is an empty list", file: "internal/comic/comic.go", edit: edit{"if len(candidates) == 0 {", "if false {"}, unit: "./internal/comic/", scenario: differential},
	{name: "reading order: only jpeg, png and webp are pages", file: "internal/comic/comic.go", edit: edit{`"webp": "image/webp"}`, `"webp": "image/webp", "gif": "image/gif"}`}, unit: "./internal/comic/", scenario: differential},
	{name: "reading order: a non-CBZ asset has a reading order", file: "internal/gohttp/handlers.go", edit: edit{"if chosen.Format != \"cbz\" {", "if chosen.Format == \"\" {"}, unit: "./internal/gohttp/", scenario: differential},
	{name: "assets: a candidate that changed between matching and inspection is served", file: "internal/library/assets.go", edit: edit{"if inspected.ID != id {", "if inspected.ID == \"\" {"}, unit: "./internal/library/"},
	{name: "archive: a hidden second directory record is accepted", file: "internal/zipdirectory/zipdirectory.go", edit: edit{"if len(candidates) != 1 {", "if len(candidates) == 0 {"}, unit: "./internal/zipdirectory/", scenario: differential},
	{name: "archive: a second disk is accepted", file: "internal/zipdirectory/zipdirectory.go", edit: edit{"if disk != 0 || directoryDisk != 0 || diskEntries != total ||", "if disk > 65535 || directoryDisk != 0 || diskEntries != total ||"}, unit: "./internal/zipdirectory/", scenario: differential},
	{name: "archive: a ZIP64 locator is ignored", file: "internal/zipdirectory/zipdirectory.go", edit: edit{"if bytes.Equal(locator, zip64Locator) {", "if len(locator) == 0 && bytes.Equal(locator, zip64Locator) {"}, unit: "./internal/zipdirectory/", scenario: differential},
	{name: "archive: more than ten thousand entries are accepted", file: "internal/zipdirectory/zipdirectory.go", edit: edit{"total > MaxEntries ||", "total > MaxEntries*2 ||"}, unit: "./internal/zipdirectory/", scenario: differential},
	{name: "archive: a directory over two mebibytes is accepted", file: "internal/zipdirectory/zipdirectory.go", edit: edit{"directorySize > MaxDirectoryBytes ||", "directorySize > MaxDirectoryBytes*4 ||"}, unit: "./internal/zipdirectory/", scenario: differential},
	{name: "archive: a directory that does not end at its record is accepted", file: "internal/zipdirectory/zipdirectory.go", edit: edit{"|| offset+directorySize != eocdOffset {", "|| false {"}, unit: "./internal/zipdirectory/", scenario: differential},
	{name: "archive: a name over 1024 bytes is accepted", file: "internal/zipdirectory/zipdirectory.go", edit: edit{"if len(raw) < 1 || len(raw) > MaxNameBytes {", "if len(raw) < 1 || len(raw) > MaxNameBytes*2 {"}, unit: "./internal/zipdirectory/", scenario: differential},
	{name: "archive: encryption and reserved flags are accepted", file: "internal/zipdirectory/zipdirectory.go", edit: edit{"supported := flags&^allowedFlags == 0 && (method", "supported := (method"}, unit: "./internal/zipdirectory/", scenario: differential},
	{name: "archive: an unsupported compression method is accepted", file: "internal/zipdirectory/zipdirectory.go", edit: edit{"(method == Stored || method == Deflated) &&", "true &&"}, unit: "./internal/zipdirectory/", scenario: differential},
	{name: "archive: a Unicode path override or AES extra is accepted", file: "internal/zipdirectory/zipdirectory.go", edit: edit{"if slices.Contains(refusedExtraID, identifier) || cursor+4+length > len(extras) {", "if identifier == 0xffff && slices.Contains(refusedExtraID, identifier) || cursor+4+length > len(extras) {"}, unit: "./internal/zipdirectory/", scenario: differential},
	{name: "archive: a link or special file is accepted", file: "internal/zipdirectory/zipdirectory.go", edit: edit{"if madeBy>>8 != 3 {", "if true {"}, unit: "./internal/zipdirectory/", scenario: differential},
	{name: "archive: names equal after composition are distinct", file: "internal/zipdirectory/zipdirectory.go", edit: edit{"normalised := norm.NFC.String(name)", "normalised := name + norm.NFC.String(\"\")"}, unit: "./internal/zipdirectory/", scenario: differential},
	{name: "archive: control and separator characters are accepted in names", file: "internal/zipdirectory/zipdirectory.go", edit: edit{"if strings.ContainsFunc(name, unsafeCharacter) || strings.HasPrefix(name, \"/\") {", "if strings.HasPrefix(name, \"/\") {"}, unit: "./internal/zipdirectory/", scenario: differential},
	{name: "archive: a parent directory segment is accepted", file: "internal/zipdirectory/zipdirectory.go", edit: edit{`part == "" || part == "." || part == ".."`, `part == "" || part == "."`}, unit: "./internal/zipdirectory/", scenario: differential},
	{name: "archive: names that are not UTF-8 are accepted", file: "internal/zipdirectory/zipdirectory.go", edit: edit{"if !utf8.Valid(raw) {", "if !utf8.Valid(raw) && false {"}, unit: "./internal/zipdirectory/", scenario: differential},
	{name: "archive: a local name that differs is accepted", file: "internal/zipdirectory/zipdirectory.go", edit: edit{"matches = string(name) == entry.Name &&", "matches = len(name) >= 0 &&"}, unit: "./internal/zipdirectory/", scenario: differential},
	{name: "archive: local flags that differ are accepted", file: "internal/zipdirectory/zipdirectory.go", edit: edit{"flags == entry.Flags && method == entry.Method", "flags >= 0 && method == entry.Method"}, unit: "./internal/zipdirectory/", scenario: differential},
	{name: "archive: local sizes that differ are accepted", file: "internal/zipdirectory/zipdirectory.go", edit: edit{"agrees := crc == entry.CRC && compressed == entry.CompressedSize && size == entry.Size", "agrees := true"}, unit: "./internal/zipdirectory/", scenario: differential},
	{name: "archive: a data descriptor is not part of an entry's extent", file: "internal/zipdirectory/zipdirectory.go", edit: edit{"\t\t\tfinish += descriptorBytes\n", ""}, unit: "./internal/zipdirectory/", scenario: differential},
	{name: "archive: entries that overlap are accepted", file: "internal/zipdirectory/zipdirectory.go", edit: edit{"if extents[index].start < extents[index-1].finish {", "if false {"}, unit: "./internal/zipdirectory/", scenario: differential},
	{name: "archive: entries that run into the directory are accepted", file: "internal/zipdirectory/zipdirectory.go", edit: edit{"if finish > directoryOffset {", "if false {"}, unit: "./internal/zipdirectory/", scenario: differential},
	{name: "archive: a scan ignores cancellation", file: "internal/zipdirectory/zipdirectory.go", edit: edit{"func (r reader) read(length, offset int64) ([]byte, error) {\n\tif err := r.ctx.Err(); err != nil {\n\t\treturn nil, err\n\t}", "func (r reader) read(length, offset int64) ([]byte, error) {"}, unit: "./internal/zipdirectory/"},
	{name: "archive: a directory scan ignores cancellation", file: "internal/zipdirectory/zipdirectory.go", edit: edit{"\tfor range count {\n\t\tif err := ctx.Err(); err != nil {\n\t\t\treturn nil, err\n\t\t}", "\tfor range count {"}, unit: "./internal/zipdirectory/"},
	{name: "progress: a page place is stored without validation", file: "internal/gohttp/progress.go", edit: edit{"case write.Locator == nil || !fixedLayout(found.Asset.Format):", "case true:"}, unit: "./internal/gohttp/", scenario: differential},
	{name: "progress: a comic place is not compared with the reading order", file: "internal/gohttp/progress.go", edit: edit{"case found.Asset.Format == \"pdf\":\n\t\treturn \"\", nil", "case true:\n\t\treturn \"\", nil"}, unit: "./internal/gohttp/", scenario: differential},
	{name: "progress: the href of a comic page is not compared", file: "internal/gohttp/progress.go", edit: edit{"pages[place.Page-1].Href != place.Href ||", "false ||"}, unit: "./internal/gohttp/", scenario: differential},
	{name: "progress: the type of a comic page is not compared", file: "internal/gohttp/progress.go", edit: edit{"pages[place.Page-1].MediaType != place.MediaType {", "false {"}, unit: "./internal/gohttp/", scenario: differential},
	{name: "progress: an asset id that is not listed is accepted", file: "internal/gohttp/progress.go", edit: edit{"case found.Asset == nil:\n\t\treturn assetGone, nil", "case found.Asset == nil:\n\t\treturn \"\", nil"}, unit: "./internal/gohttp/", scenario: differential},
	{name: "progress: a PDF page above the bound is accepted", file: "internal/checkpoint/checkpoint.go", edit: edit{"number.Cmp(big.NewInt(maxPages)) > 0", "number.Cmp(big.NewInt(maxPages*2)) > 0"}, unit: "./internal/gohttp/", scenario: differential},
	{name: "progress: a PDF fragment for another page is accepted", file: "internal/checkpoint/checkpoint.go", edit: edit{"fragments.Kind != strictjson.Null && !singlePage", "fragments.Kind != strictjson.Null && !singlePage && false"}, unit: "./internal/gohttp/", scenario: differential},
	{name: "progress: a comic place may carry fragments", file: "internal/checkpoint/checkpoint.go", edit: edit{"if hasFragments {", "if hasFragments && false {"}, unit: "./internal/gohttp/", scenario: differential},
	{name: "progress: text positions are accepted beside a page", file: "internal/checkpoint/checkpoint.go", edit: edit{"!withinKeys(locations, fixedLocationKeys) ||", "false ||"}, unit: "./internal/gohttp/", scenario: differential},
	{name: "progress: an over-long page title is accepted", file: "internal/checkpoint/checkpoint.go", edit: edit{"len(title.Text) > maxTitleBytes", "len(title.Text) > maxTitleBytes*2"}, unit: "./internal/gohttp/", scenario: differential},
	{name: "progress: a comic archive that fails its check is accepted", file: "internal/gohttp/progress.go", edit: edit{"case errors.As(err, &invalid):\n\t\treturn \"This comic archive is unsupported or unsafe\", nil", "case errors.As(err, &invalid):\n\t\treturn \"\", nil"}, unit: "./internal/gohttp/"},
	{name: "progress: a cancelled page scan is reported as a refused place", file: "internal/gohttp/progress.go", edit: edit{"case errors.Is(err, media.ErrNoPinnedOpen), errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):\n\t\treturn \"\", err\n\tcase errors.Is(err, errAssetChanged):", "case errors.Is(err, media.ErrNoPinnedOpen), errors.Is(err, context.DeadlineExceeded):\n\t\treturn \"\", err\n\tcase errors.Is(err, errAssetChanged):"}, unit: "./internal/gohttp/"},
	{name: "assets: a cancelled scan is reported as a missing asset", file: "internal/gohttp/handlers.go", edit: edit{"case errors.Is(err, media.ErrNoPinnedOpen), errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):\n\t\tmapFailure(w, result, err)", "case errors.Is(err, media.ErrNoPinnedOpen), errors.Is(err, context.DeadlineExceeded):\n\t\tmapFailure(w, result, err)"}, unit: "./internal/gohttp/"},
	{name: "assets: a kernel without confined opens is reported as a missing asset", file: "internal/gohttp/handlers.go", edit: edit{"case errors.Is(err, media.ErrNoPinnedOpen), errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):\n\t\tmapFailure(w, result, err)", "case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):\n\t\tmapFailure(w, result, err)"}, unit: "./internal/gohttp/"},
	{name: "logging: request paths are logged", file: "internal/gohttp/app.go", edit: edit{`slog.String("route", found.name)`, `slog.String("route", r.URL.RequestURI())`}, unit: "./internal/gohttp/", scenario: "TestSensitiveValues"},
	{name: "transfer: an expired grant is accepted", file: "internal/railsmsg/encryptor.go", edit: edit{"!now.Before(expires) ||", "false && !now.Before(expires) ||"}, unit: "./internal/transfergrant/", scenario: differential},
	{name: "transfer: a grant is refused one tick before its expiry", file: "internal/railsmsg/encryptor.go", edit: edit{"!now.Before(expires) ||", "now.After(expires) ||"}, unit: "./internal/transfergrant/", scenario: differential},
	{name: "transfer: the purpose of a grant is not checked", file: "internal/railsmsg/encryptor.go", edit: edit{"|| envelope.Rails.Pur != purpose", ""}, unit: "./internal/transfergrant/"},
	{name: "transfer: grants are derived with another salt", file: "internal/transfergrant/transfergrant.go", edit: edit{`Salt           = "shelfarr consumer transfer grant v1"`, `Salt           = "shelfarr consumer transfer grant v2"`}, unit: "./internal/transfergrant/", scenario: differential},
	{name: "transfer: the nonce is not random", file: "internal/railsmsg/encryptor.go", edit: edit{"if _, err := rand.Read(nonce); err != nil {", "if _, err := rand.Read(nonce[:0]); err != nil {"}, unit: "./internal/transfergrant/"},
	{name: "transfer: the expiry is written without milliseconds", file: "internal/railsmsg/encryptor.go", edit: edit{`const encryptedExpiryLayout = "2006-01-02T15:04:05.000Z"`, `const encryptedExpiryLayout = "2006-01-02T15:04:05Z"`}, unit: "./internal/transfergrant/", scenario: differential},
	{name: "transfer: the claim types are not strict", file: "internal/transfergrant/transfergrant.go", edit: edit{"!number.MatchString(string(document.Token)) ||", "false ||"}, unit: "./internal/transfergrant/"},
	{name: "transfer: a lifetime ignores the issuing token's expiry", file: "internal/transfergrant/transfergrant.go", edit: edit{"if tokenExpiry != nil && tokenExpiry.Before(expires) {", "if false {"}, unit: "./internal/transfergrant/", scenario: differential},
	{name: "transfer: the lifetime is longer than a day", file: "internal/transfergrant/transfergrant.go", edit: edit{"Lifetime       = 24 * time.Hour", "Lifetime       = 25 * time.Hour"}, unit: "./internal/transfergrant/", scenario: differential},
	{name: "transfer: the grant query accepts other characters", file: "internal/transfergrant/transfergrant.go", edit: edit{"|| character == '_' || character == '-') {", "|| character == '_' || character == '-' || character == '%' || character == '+' || character == '=') {"}, unit: "./internal/transfergrant/", scenario: differential},
	{name: "transfer: a one character shorter grant is accepted", file: "internal/transfergrant/transfergrant.go", edit: edit{"len(value) < minGrantLength", "len(value) < minGrantLength-1"}, unit: "./internal/transfergrant/"},
	{name: "transfer: the grant query may carry other parameters", file: "internal/transfergrant/transfergrant.go", edit: edit{"value, found := strings.CutPrefix(rawQuery, queryKey)", "_, value, found := strings.Cut(rawQuery, queryKey)"}, unit: "./internal/transfergrant/", scenario: differential},
	{name: "transfer: a grant opens another book", file: "internal/gohttp/transfer.go", edit: edit{"!ok || claims.BookID != found.id ||", "!ok ||"}, unit: "./internal/gohttp/", unitRun: transferUnitTests, scenario: differential},
	{name: "transfer: a grant opens another asset", file: "internal/gohttp/transfer.go", edit: edit{"|| claims.AssetID != found.assetID {", "{"}, unit: "./internal/gohttp/", unitRun: transferUnitTests, scenario: differential},
	{name: "transfer: a scope array holding something other than text is approximated", file: "internal/account/account.go", edit: edit{"if element.Kind != strictjson.String {", "if false && element.Kind != strictjson.String {"}, unit: "./internal/gohttp/", unitRun: transferUnitTests},
	{name: "transfer: a refused media pool answers a grant in the open", file: "internal/gohttp/app.go", edit: edit{"if found.kind == routeTransfer {\n\t\tsetTransferPrivacy(w.Header())\n\t}\n", ""}, unit: "./internal/gohttp/", unitRun: transferUnitTests},
	{name: "transfer: a mint does not check that the asset is current when it opens it", file: "internal/gohttp/transfer.go", edit: edit{"\tfile, ok := a.openAsset(w, result, *book, *chosen)\n\tif !ok {\n\t\treturn\n\t}\n\tfile.Close()\n", ""}, scenario: "TestAMintRechecks"},
	{name: "transfer: a grant opens for a token that changed owner", file: "internal/bearer/bearer.go", edit: edit{"|| token.UserID.Int64 != claims.UserID {", "{"}, unit: "./internal/gohttp/", unitRun: transferUnitTests, scenario: differential},
	{name: "transfer: a deleted account's grant still opens", file: "internal/bearer/bearer.go", edit: edit{"user == nil || user.Deleted {", "user == nil {"}, unit: "./internal/gohttp/", unitRun: transferUnitTests, scenario: differential},
	{name: "transfer: a grant outlives the loss of library:read", file: "internal/bearer/bearer.go", edit: edit{"return account.Principal{Scopes: scopes}.HasScope(transfergrant.Scope), nil", "return account.Principal{Scopes: scopes}.HasScope(transfergrant.Scope) || true, nil"}, unit: "./internal/gohttp/", unitRun: transferUnitTests, scenario: differential},
	{name: "transfer: a use records the credential as used", file: "internal/bearer/bearer.go", edit: edit{"return account.Principal{Scopes: scopes}.HasScope(transfergrant.Scope), nil", "a.DB.TouchToken(ctx, token.ID, a.Now())\n\treturn account.Principal{Scopes: scopes}.HasScope(transfergrant.Scope), nil"}, unit: "./internal/gohttp/", unitRun: transferUnitTests, scenario: differential},
	{name: "transfer: a use adopts the replacement credential", file: "internal/bearer/bearer.go", edit: edit{"return account.Principal{Scopes: scopes}.HasScope(transfergrant.Scope), nil", "a.DB.RetireReplaced(ctx, *token, a.Now)\n\treturn account.Principal{Scopes: scopes}.HasScope(transfergrant.Scope), nil"}, scenario: differential},
	{name: "transfer: the route answers POST", file: "internal/gohttp/routes.go", edit: edit{"if method != http.MethodGet && method != http.MethodHead {\n\t\treturn route{kind: routeNone}", "if method != http.MethodGet && method != http.MethodHead && method != http.MethodPost {\n\t\treturn route{kind: routeNone}"}, unit: "./internal/gohttp/", unitRun: transferUnitTests, scenario: differential},
	{name: "transfer: a transfer is not admitted as a media stream", file: "internal/gohttp/app.go", edit: edit{"if found.kind == routeAsset || found.kind == routeTransfer {", "if found.kind == routeAsset {"}, unit: "./internal/gohttp/", unitRun: transferUnitTests},
	{name: "transfer: an answer is cacheable", file: "internal/gohttp/transfer.go", edit: edit{`header.Set("Cache-Control", "private, no-store")`, `header.Set("Cache-Control", "private")`}, unit: "./internal/gohttp/", unitRun: transferUnitTests, scenario: differential},
	{name: "transfer: an answer carries a referrer", file: "internal/gohttp/transfer.go", edit: edit{`header.Set("Referrer-Policy", "no-referrer")`, `header.Set("Referrer-Policy", "same-origin")`}, unit: "./internal/gohttp/", unitRun: transferUnitTests, scenario: differential},
	{name: "transfer: a mint request body is not bounded", file: "internal/gohttp/transfer.go", edit: edit{"const grantBodyLimit = 64 << 10", "const grantBodyLimit = 64 << 30"}, unit: "./internal/gohttp/", unitRun: transferUnitTests, scenario: differential},
	{name: "transfer: a malformed JSON mint body is accepted", file: "internal/gohttp/transfer.go", edit: edit{"len(body) > 0 && !json.Valid(body)", "len(body) > 0 && !json.Valid(body) && false"}, unit: "./internal/gohttp/", unitRun: transferUnitTests, scenario: differential},
	{name: "transfer: the grant carries the user instead of the token", file: "internal/gohttp/transfer.go", edit: edit{"TokenID: principal.TokenID,", "TokenID: principal.UserID,"}, scenario: differential},
	{name: "transfer: the mint answers an absolute expiry with fractions", file: "internal/gohttp/transfer.go", edit: edit{`expires.UTC().Format("2006-01-02T15:04:05Z")`, `expires.UTC().Format("2006-01-02T15:04:05.000Z")`}, unit: "./internal/gohttp/", unitRun: transferUnitTests, scenario: differential},
}

func copyModule(t *testing.T, destination string) {
	t.Helper()
	source, err := filepath.Abs("../..")
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range []string{"go.mod", "go.sum", "cmd", "internal", "e2e/httpruntime"} {
		root := filepath.Join(source, entry)
		walk := func(path string, directory fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			relative, _ := filepath.Rel(source, path)
			target := filepath.Join(destination, relative)
			if directory.IsDir() {
				return os.MkdirAll(target, 0o700)
			}
			data, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			return os.WriteFile(target, data, 0o600)
		}
		if info, err := os.Stat(root); err == nil && !info.IsDir() {
			data, _ := os.ReadFile(root)
			if err := os.WriteFile(filepath.Join(destination, entry), data, 0o600); err != nil {
				t.Fatal(err)
			}
			continue
		}
		if err := filepath.WalkDir(root, walk); err != nil {
			t.Fatal(err)
		}
	}
}

func TestMutantsAreDetected(t *testing.T) {
	for _, f := range fixtures(t) {
		for _, required := range []string{filepath.Join(f.dir, f.doc.Database), f.secretFile(), f.doc.BundleMediaRoot, f.doc.ExtraMediaRoot} {
			if _, err := os.Stat(required); err != nil {
				t.Fatalf("the %s fixture is incomplete, so no mutant run could prove anything", f.name)
			}
		}
		before := fixtureDigest(t, f)
		t.Cleanup(func() {
			if fixtureDigest(t, f) != before {
				t.Errorf("the %s fixture changed while mutants ran, so their verdicts prove nothing", f.name)
			}
		})
	}
	deadline := stageDeadline(t)
	proveTheUnmutatedModulePassesEveryMutantRun(t, deadline)
	for _, candidate := range mutants {
		t.Run(candidate.name, func(t *testing.T) {
			t.Parallel()
			directory := t.TempDir()
			copyModule(t, directory)
			path := filepath.Join(directory, candidate.file)
			original, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if strings.Count(string(original), candidate.edit.old) != 1 {
				t.Fatalf("the mutation target occurs %d times", strings.Count(string(original), candidate.edit.old))
			}
			if err := os.WriteFile(path, []byte(strings.Replace(string(original), candidate.edit.old, candidate.edit.new, 1)), 0o600); err != nil {
				t.Fatal(err)
			}
			if output, err := childRunner.build(directory, deadline); err != nil {
				t.Fatalf("the mutant does not compile, which proves nothing: %s", output)
			}
			var steps []mutantStep
			if candidate.unit != "" {
				steps = append(steps, func() (verdict, string) {
					return childRunner.test(directory, "./"+strings.TrimPrefix(candidate.unit, "./"), candidate.unitRun, false, deadline)
				})
			}
			if candidate.scenario != "" {
				steps = append(steps, func() (verdict, string) {
					return childRunner.test(directory, "./e2e/httpruntime/", candidate.scenario, true, deadline)
				})
			}
			if killed, evidence := firstDetection(steps); !killed {
				t.Fatal(evidence)
			}
		})
	}
}

func tail(text string) string {
	if len(text) > 2000 {
		return text[len(text)-2000:]
	}
	return text
}

type mutantCommand struct {
	packagePath string
	pattern     string
	tagged      bool
}

func mutantCommands() []mutantCommand {
	seen := map[mutantCommand]bool{}
	var commands []mutantCommand
	for _, candidate := range mutants {
		for _, command := range []mutantCommand{{"./" + strings.TrimPrefix(candidate.unit, "./"), candidate.unitRun, false}, {"./e2e/httpruntime/", candidate.scenario, true}} {
			if command.packagePath == "./" || command.tagged && command.pattern == "" || seen[command] {
				continue
			}
			seen[command] = true
			commands = append(commands, command)
		}
	}
	return commands
}

func proveTheUnmutatedModulePassesEveryMutantRun(t *testing.T, deadline time.Time) {
	t.Helper()
	directory := t.TempDir()
	copyModule(t, directory)
	if output, err := childRunner.build(directory, deadline); err != nil {
		t.Fatalf("the unmutated module does not build: %s", output)
	}
	t.Run("unmutated", func(t *testing.T) {
		for _, command := range mutantCommands() {
			t.Run(command.packagePath+" "+command.pattern, func(t *testing.T) {
				t.Parallel()
				if outcome, evidence := childRunner.test(directory, command.packagePath, command.pattern, command.tagged, deadline); outcome != survived {
					t.Fatalf("this run fails without any mutation, so it cannot prove a mutant: %s", evidence)
				}
			})
		}
	})
	if t.Failed() {
		t.FailNow()
	}
}

func fixtureDigest(t *testing.T, f fixture) string {
	t.Helper()
	sum := sha256.New()
	for _, path := range []string{filepath.Join(f.dir, "cases.json"), filepath.Join(f.dir, f.doc.Database), f.secretFile(), filepath.Join(f.dir, "secrets", "tokens.json")} {
		data, err := os.ReadFile(path)
		if err != nil {
			return "unreadable"
		}
		sum.Write(data)
	}
	for _, root := range []string{f.doc.BundleMediaRoot, f.doc.ExtraMediaRoot} {
		filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
			if err != nil {
				sum.Write([]byte("missing " + path))
				return nil
			}
			fmt.Fprintf(sum, "%s %s\n", path, entry.Type())
			if entry.Type().IsRegular() {
				if file, err := os.Open(path); err == nil {
					io.Copy(sum, file)
					file.Close()
				}
			}
			return nil
		})
	}
	return hex.EncodeToString(sum.Sum(nil))
}
