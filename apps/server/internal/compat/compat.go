package compat

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"math/big"
	"strconv"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/account"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/arcrypt"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/assetid"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/bundle"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/consumer"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/library"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
)

const (
	StatusPass = "pass"
	StatusFail = "fail"
)

type Check struct {
	Name     string   `json:"name"`
	Status   string   `json:"status"`
	Cases    int      `json:"cases"`
	Failures []string `json:"failures,omitempty"`
}

type Report struct {
	FixtureFormat  int          `json:"fixture_format"`
	Origin         string       `json:"origin"`
	SchemaRevision string       `json:"schema_revision"`
	CoverageDigest string       `json:"coverage_digest"`
	Passed         bool         `json:"passed"`
	Checks         []Check      `json:"checks"`
	Gaps           []bundle.Gap `json:"gaps"`
}

type Options struct {
	Timeout    time.Duration
	LegacySHA1 bool
	Now        func() time.Time
}

type runner struct {
	bundle    *bundle.Bundle
	db        *store.DB
	decryptor *arcrypt.Decryptor
	options   Options
	checks    []Check
}

func Run(ctx context.Context, directory string, options Options) (Report, error) {
	if options.Now == nil {
		options.Now = time.Now
	}
	ctx, cancel := context.WithTimeout(ctx, options.Timeout)
	defer cancel()
	opened, err := bundle.Open(ctx, directory)
	if err != nil {
		return Report{}, err
	}
	before, err := opened.Snapshot(ctx)
	if err != nil {
		return Report{}, err
	}
	database, err := store.Open(ctx, opened.DatabasePath())
	if err != nil {
		return Report{}, err
	}
	decryptor, err := arcrypt.NewDecryptor(opened.Credentials.Encryption.PrimaryKey, opened.Credentials.Encryption.KeyDerivationSalt, arcrypt.Options{LegacySHA1: options.LegacySHA1})
	if err != nil {
		database.Close()
		return Report{}, err
	}
	current := &runner{bundle: opened, db: database, decryptor: decryptor, options: options}
	current.run(ctx)
	closeErr := database.Close()
	current.checkReadOnly(ctx, before, closeErr)
	return current.report(), nil
}

func (r *runner) report() Report {
	passed := true
	for _, check := range r.checks {
		if check.Status != StatusPass {
			passed = false
		}
	}
	manifest := r.bundle.Manifest
	return Report{FixtureFormat: manifest.FixtureFormat, Origin: manifest.Origin, SchemaRevision: manifest.Schema.Revision,
		CoverageDigest: manifest.Coverage.Digest, Passed: passed, Checks: r.checks, Gaps: manifest.Coverage.Gaps}
}

func (r *runner) record(name string, cases int, failures []string) {
	status := StatusPass
	if len(failures) > 0 || cases == 0 {
		status = StatusFail
		if cases == 0 {
			failures = append(failures, "no-cases")
		}
	}
	r.checks = append(r.checks, Check{Name: name, Status: status, Cases: cases, Failures: failures})
}

func (r *runner) run(ctx context.Context) {
	r.checkSchema(ctx)
	r.checkIdentityVectors()
	r.checkLibraryAssets(ctx)
	r.checkPasswords(ctx)
	r.checkEncryptedColumns(ctx)
	r.checkTamperedEnvelopes()
	r.checkConsumerProjection(ctx)
}

func (r *runner) checkSchema(ctx context.Context) {
	revision, err := r.db.SchemaRevision(ctx)
	var failures []string
	if err != nil || revision != r.bundle.Manifest.Schema.Revision {
		failures = append(failures, "schema-revision-mismatch")
	}
	r.record("schema-revision", 1, failures)
}

func parseUnsigned(text string) (uint64, bool) {
	value, err := strconv.ParseUint(text, 10, 64)
	return value, err == nil
}

func vectorInput(vector bundle.IdentityVector) (assetid.Input, bool) {
	bookID, bookErr := strconv.ParseInt(vector.BookID, 10, 64)
	device, deviceOK := parseUnsigned(vector.Device)
	inode, inodeOK := parseUnsigned(vector.Inode)
	size, sizeErr := strconv.ParseInt(vector.Size, 10, 64)
	mtime, mtimeErr := assetid.ParseRational(vector.Mtime)
	ctime, ctimeErr := assetid.ParseRational(vector.Ctime)
	if bookErr != nil || !deviceOK || !inodeOK || sizeErr != nil || mtimeErr != nil || ctimeErr != nil {
		return assetid.Input{}, false
	}
	return assetid.Input{BookID: bookID, StoredPath: vector.FilePath, CanonicalPath: vector.Path,
		Stat: assetid.Stat{Device: device, Inode: inode, Size: size, Mtime: mtime, Ctime: ctime}}, true
}

func (r *runner) checkIdentityVectors() {
	var failures []string
	for _, vector := range r.bundle.Identity.Vectors {
		input, ok := vectorInput(vector)
		if !ok {
			failures = append(failures, vector.Name+":malformed")
			continue
		}
		if assetid.ID(input) != vector.ID {
			failures = append(failures, vector.Name+":id-mismatch")
		}
	}
	r.record("identity-vectors", len(r.bundle.Identity.Vectors), failures)
}

func (r *runner) checkLibraryAssets(ctx context.Context) {
	failures := []string{}
	roots, err := library.OutputRoots(ctx, r.db)
	if err != nil {
		r.record("library-assets", 0, []string{"roots:" + reason(err)})
		return
	}
	lister := library.Lister{Roots: roots}
	for _, expected := range r.bundle.Assets.Books {
		id, err := strconv.ParseInt(expected.BookID, 10, 64)
		if err != nil {
			failures = append(failures, expected.Key+":malformed")
			continue
		}
		books, err := r.db.AcquiredBooks(ctx, []int{store.BookTypeAudiobook, store.BookTypeEbook, store.BookTypeComicbook})
		if err != nil {
			failures = append(failures, expected.Key+":database")
			continue
		}
		failures = append(failures, compareBook(lister, books, id, expected)...)
	}
	r.record("library-assets", len(r.bundle.Assets.Books), failures)
}

func compareBook(lister library.Lister, books []store.Book, id int64, expected bundle.BookAssets) []string {
	var book *store.Book
	for index := range books {
		if books[index].ID == id {
			book = &books[index]
		}
	}
	if book == nil {
		if len(expected.Assets) == 0 {
			return nil
		}
		return []string{expected.Key + ":book-missing"}
	}
	if book.BookType == store.BookTypeComicbook {
		return nil
	}
	listing, err := lister.List(*book, book.FilePath.String)
	if err != nil {
		return []string{expected.Key + ":" + reason(err)}
	}
	if listing.Unavailable != expected.Unavailable || len(listing.Assets) != len(expected.Assets) {
		return []string{expected.Key + ":listing-mismatch"}
	}
	var failures []string
	for index, asset := range listing.Assets {
		failures = append(failures, compareAsset(expected.Key, asset, expected.Assets[index])...)
	}
	return failures
}

func compareAsset(key string, asset library.Asset, expected bundle.AssetRecord) []string {
	var failures []string
	label := key + "#" + strconv.Itoa(expected.Position)
	if asset.ID != expected.ID {
		failures = append(failures, label+":id-mismatch")
	}
	if asset.Path != expected.Path || asset.Root != expected.Root || asset.Filename != expected.Filename || asset.Format != expected.Format ||
		asset.MediaType != expected.MediaType || asset.SizeBytes != expected.SizeBytes || asset.Position != expected.Position {
		failures = append(failures, label+":field-mismatch")
	}
	if !statMatches(asset.Stat, expected) {
		failures = append(failures, label+":stat-mismatch")
	}
	return failures
}

func statMatches(stat assetid.Stat, expected bundle.AssetRecord) bool {
	mtime, mtimeErr := assetid.ParseRational(expected.Mtime)
	ctime, ctimeErr := assetid.ParseRational(expected.Ctime)
	if mtimeErr != nil || ctimeErr != nil {
		return false
	}
	return strconv.FormatUint(stat.Device, 10) == expected.Device && strconv.FormatUint(stat.Inode, 10) == expected.Inode &&
		strconv.FormatInt(stat.Size, 10) == expected.Size && stat.Mtime.Cmp(mtime) == 0 && stat.Ctime.Cmp(ctime) == 0
}

func reason(err error) string {
	switch {
	case errors.Is(err, library.ErrReference):
		return "reference-import-unsupported"
	case errors.Is(err, library.ErrUnsupportedPath):
		return "path-form-unsupported"
	case errors.Is(err, library.ErrUnsupportedRoot):
		return "root-setting-unsupported"
	case errors.Is(err, account.ErrUnsupportedAdoption):
		return "token-adoption-unsupported"
	case errors.Is(err, consumer.ErrUnsupportedPagination):
		return "pagination-unsupported"
	case errors.Is(err, consumer.ErrUnsupportedValue), errors.Is(err, store.ErrUnsupported), errors.Is(err, account.ErrUnsupportedScopes):
		return "value-unsupported"
	case errors.Is(err, store.ErrTimestamp):
		return "timestamp-invalid"
	}
	if kind := arcrypt.KindOf(err); kind != "" {
		return string(kind)
	}
	return "error"
}

func (r *runner) checkPasswords(ctx context.Context) {
	var failures []string
	cases := 0
	for _, record := range r.bundle.Accounts.Accounts {
		user, err := r.db.UserByUsername(ctx, record.Username)
		if err != nil || user == nil {
			failures = append(failures, record.Username+":user-missing")
			continue
		}
		if strconv.FormatInt(user.ID, 10) != record.ID || user.Name != record.Name || user.Deleted != record.Deleted || len(user.PasswordDigest) < 4 || user.PasswordDigest[:4] != record.DigestPrefix {
			failures = append(failures, record.Username+":account-mismatch")
		}
		credentials, known := r.bundle.Credentials.Users[record.Username]
		if !known {
			failures = append(failures, record.Username+":credentials-missing")
			continue
		}
		for _, candidate := range credentials.Candidates {
			cases++
			expected, listed := record.Authenticate[candidate.Label]
			if !listed || account.PasswordMatches(user.PasswordDigest, candidate.Value) != expected {
				failures = append(failures, record.Username+":"+candidate.Label+":verdict-mismatch")
			}
		}
	}
	r.record("passwords", cases, failures)
}

func (r *runner) checkEncryptedColumns(ctx context.Context) {
	var failures []string
	for _, column := range r.bundle.Encryption.Columns {
		label := column.Table + "." + column.Column + "#" + column.ID
		id, err := strconv.ParseInt(column.ID, 10, 64)
		if err != nil {
			failures = append(failures, label+":malformed")
			continue
		}
		stored, err := r.db.EncryptedValue(ctx, column.Table, column.Column, id)
		if err != nil {
			failures = append(failures, label+":database")
			continue
		}
		if !stored.Valid || column.Null {
			if stored.Valid != !column.Null {
				failures = append(failures, label+":null-mismatch")
			}
			continue
		}
		plaintext, err := r.decryptor.Decrypt([]byte(stored.String))
		if err != nil {
			failures = append(failures, label+":"+reason(err))
			continue
		}
		if digest(plaintext) != column.PlaintextSHA256 || len(plaintext) != column.PlaintextBytes {
			failures = append(failures, label+":plaintext-mismatch")
		}
	}
	r.record("encrypted-columns", len(r.bundle.Encryption.Columns), failures)
}

func digest(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func (r *runner) checkTamperedEnvelopes() {
	var failures []string
	for _, entry := range r.bundle.Encryption.Tampered {
		plaintext, err := r.decryptor.Decrypt([]byte(entry.Envelope))
		switch entry.Outcome {
		case "ok":
			if err != nil || digest(plaintext) != entry.PlaintextSHA256 {
				failures = append(failures, entry.Name+":expected-success")
			}
		case "error":
			if err == nil {
				failures = append(failures, entry.Name+":accepted")
			} else if string(arcrypt.KindOf(err)) != entry.Category {
				failures = append(failures, entry.Name+":category-mismatch")
			}
		default:
			failures = append(failures, entry.Name+":malformed")
		}
	}
	r.record("tampered-envelopes", len(r.bundle.Encryption.Tampered), failures)
}

func (r *runner) checkConsumerProjection(ctx context.Context) {
	service := consumer.Service{Source: r.db, Now: r.options.Now}
	var failures []string
	for _, expected := range r.bundle.Responses.Cases {
		failures = append(failures, r.compareResponse(ctx, service, expected)...)
	}
	for _, refusal := range r.bundle.Responses.Refusals {
		_, err := service.Respond(ctx, consumer.Request{Path: refusal.Path, Authorization: "Bearer " + r.bundle.Credentials.Tokens[refusal.Token]})
		if refusal.GoOutcome != "unsupported_token_adoption" || !errors.Is(err, account.ErrUnsupportedAdoption) {
			failures = append(failures, refusal.Name+":not-refused")
		}
	}
	r.record("consumer-projection", len(r.bundle.Responses.Cases)+len(r.bundle.Responses.Refusals), failures)
}

func (r *runner) compareResponse(ctx context.Context, service consumer.Service, expected bundle.ResponseCase) []string {
	authorization := ""
	if expected.Token != nil {
		raw, known := r.bundle.Credentials.Tokens[*expected.Token]
		if !known {
			return []string{expected.Name + ":token-missing"}
		}
		authorization = "Bearer " + raw
	}
	actual, err := service.Respond(ctx, consumer.Request{Path: expected.Path, Authorization: authorization})
	if err != nil {
		return []string{expected.Name + ":" + reason(err)}
	}
	var failures []string
	if actual.Status != expected.Status {
		return []string{expected.Name + ":status-mismatch"}
	}
	if expected.CacheControl != nil && actual.CacheControl != *expected.CacheControl {
		failures = append(failures, expected.Name+":cache-control-mismatch")
	}
	switch expected.Compare {
	case "status":
	case "empty":
		if len(actual.Body) != 0 {
			failures = append(failures, expected.Name+":body-not-empty")
		}
	case "json":
		equal, err := JSONEqual(actual.Body, expected.Body)
		if err != nil || !equal {
			failures = append(failures, expected.Name+":body-mismatch")
		}
	default:
		failures = append(failures, expected.Name+":malformed")
	}
	return failures
}

func (r *runner) checkReadOnly(ctx context.Context, before bundle.Snapshot, closeErr error) {
	var failures []string
	if closeErr != nil {
		failures = append(failures, "close-database")
	}
	after, err := r.bundle.Snapshot(ctx)
	if err != nil {
		r.record("read-only", 1, append(failures, "snapshot-unavailable"))
		return
	}
	failures = append(failures, before.Differences(after)...)
	if err := r.bundle.Verify(ctx); err != nil {
		failures = append(failures, "integrity-after-run")
	}
	for name := range after {
		if bundle.IsSidecar(name) {
			failures = append(failures, "sidecar:"+name)
		}
	}
	r.record("read-only", len(after), failures)
}

func JSONEqual(left, right []byte) (bool, error) {
	var leftValue, rightValue any
	if err := decodeNumbers(left, &leftValue); err != nil {
		return false, err
	}
	if err := decodeNumbers(right, &rightValue); err != nil {
		return false, err
	}
	return valuesEqual(leftValue, rightValue), nil
}

func decodeNumbers(data []byte, target *any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	if decoder.More() {
		return errors.New("trailing data")
	}
	return nil
}

func valuesEqual(left, right any) bool {
	switch leftTyped := left.(type) {
	case nil:
		return right == nil
	case bool:
		rightTyped, ok := right.(bool)
		return ok && leftTyped == rightTyped
	case string:
		rightTyped, ok := right.(string)
		return ok && leftTyped == rightTyped
	case json.Number:
		rightTyped, ok := right.(json.Number)
		return ok && numbersEqual(leftTyped, rightTyped)
	case []any:
		rightTyped, ok := right.([]any)
		if !ok || len(leftTyped) != len(rightTyped) {
			return false
		}
		for index := range leftTyped {
			if !valuesEqual(leftTyped[index], rightTyped[index]) {
				return false
			}
		}
		return true
	case map[string]any:
		rightTyped, ok := right.(map[string]any)
		if !ok || len(leftTyped) != len(rightTyped) {
			return false
		}
		for key, value := range leftTyped {
			other, present := rightTyped[key]
			if !present || !valuesEqual(value, other) {
				return false
			}
		}
		return true
	}
	return false
}

func numbersEqual(left, right json.Number) bool {
	leftRat, leftOK := new(big.Rat).SetString(left.String())
	rightRat, rightOK := new(big.Rat).SetString(right.String())
	return leftOK && rightOK && leftRat.Cmp(rightRat) == 0
}
