package acquisition

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/url"
	"path"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/fault"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/gutenberg"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/wfstore"
)

const (
	LibraryFolder = "shelfarr-gutenberg"

	defaultEbookRoot     = "/ebooks"
	completedRequest     = 5
	selectedResult       = 1
	pendingResult        = 0
	completedDownload    = 3
	failedDownload       = 4
	queuedMessage        = "Download queued from manual result selection"
	dispatchMessage      = "Started dispatching download to a client"
	completedMessage     = "Direct download completed"
	activityCompleted    = "request.completed"
	directRecoveryFields = `direct_reservation_token, direct_staging_path, direct_staging_device, direct_staging_inode, direct_staging_parent_device,
		direct_staging_parent_inode, direct_destination_path, direct_book_path, direct_output_root, direct_output_root_device,
		direct_output_root_inode, direct_publication_kind, direct_content_manifest`
)

var (
	ErrNotSelectable       = errors.New("request_not_selectable")
	ErrResultMissing       = errors.New("result_not_found")
	ErrResultNotSelectable = errors.New("result_not_selectable")
	ErrResultNotEPUB       = errors.New("result_not_epub")
	ErrResultOffOrigin     = errors.New("result_off_origin")
	ErrBookAcquired        = errors.New("book_acquired")
	ErrDownloadsActive     = errors.New("downloads_active")
	ErrLibraryRoot         = errors.New("library_root_not_disposable")
	ErrLibraryScan         = errors.New("library_scan_configured")
	ErrImportPermissions   = errors.New("import_permissions_configured")

	SelectionRefusals = append([]error{
		ErrNotSelectable, ErrResultMissing, ErrResultNotSelectable, ErrResultNotEPUB, ErrResultOffOrigin,
		ErrBookAcquired, ErrDownloadsActive, ErrLibraryRoot, ErrLibraryScan, ErrImportPermissions,
	}, Refusals...)

	gutenbergGUID   = regexp.MustCompile(`\Agutenberg:([0-9]{1,12})\z`)
	ebookExtensions = map[string]string{"azw3": "azw3", "epub": "epub", "epub3": "epub", "kf8": "mobi", "kindle": "mobi", "mobi": "mobi", "pdf": "pdf"}

	selectionColumns = map[string][]string{
		"books":          {"file_path", "reference_target_roots", "acquisition_reservation_token", "updated_at"},
		"requests":       {"completed_at"},
		"search_results": {"acquisition_provider_id"},
		"downloads": {"name", "size_bytes", "download_type", "download_path", "external_id", "replace_library_file", "created_at", "updated_at",
			"direct_reservation_token", "direct_staging_path", "direct_staging_device", "direct_staging_inode", "direct_staging_parent_device",
			"direct_staging_parent_inode", "direct_destination_path", "direct_book_path", "direct_output_root", "direct_output_root_device",
			"direct_output_root_inode", "direct_publication_kind", "direct_content_manifest"},
		"activity_logs": {"action", "user_id", "trackable_type", "trackable_id", "details", "ip_address", "controller", "created_at", "updated_at"},
	}
)

func SelectionRefusal(err error) error {
	for _, refusal := range SelectionRefusals {
		if errors.Is(err, refusal) {
			return refusal
		}
	}
	return nil
}

type Selection struct {
	RequestID        int64
	ResultID         int64
	BookID           int64
	UserID           int64
	Generation       int64
	RequestUpdatedAt string
	ResultUpdatedAt  string
	ResultStatus     int64
	BookUpdatedAt    string
	ResultTitle      sql.NullString
	ResultSize       sql.NullInt64
	BookTitle        string
	DownloadURL      string
	Origin           gutenberg.Origin
	Root             string
	Folders          [2]string
	Name             string
}

func (s Selection) BookPath() string {
	return s.Root + "/" + strings.Join(s.Folders[:], "/") + "/" + s.Name
}

type Plan struct {
	Selection Selection
	Completed int64
}

func PlanSelection(ctx context.Context, store *wfstore.Store, requestID, resultID int64) (Plan, error) {
	var plan Plan
	err := store.Transact(ctx, func(tx *sql.Tx) error {
		var err error
		plan, err = planIn(ctx, tx, requestID, resultID)
		return err
	})
	return plan, err
}

func planIn(ctx context.Context, tx *sql.Tx, requestID, resultID int64) (Plan, error) {
	row, config, err := eligible(ctx, tx, requestID)
	if err != nil {
		return Plan{}, err
	}
	if err := verifyColumns(ctx, tx, selectionColumns); err != nil {
		return Plan{}, err
	}
	stored, err := readSettings(ctx, tx)
	if err != nil {
		return Plan{}, err
	}
	root, err := libraryRoot(stored)
	if err != nil {
		return Plan{}, err
	}
	selection := Selection{RequestID: requestID, ResultID: resultID, UserID: row.userID, Generation: row.generation, Origin: config.Origin, Root: root}
	var bookPath, reservation, bookTitle sql.NullString
	if err := tx.QueryRowContext(ctx, `SELECT r.book_id, r.updated_at, b.updated_at, b.title, b.file_path, b.acquisition_reservation_token
		FROM requests r JOIN books b ON b.id = r.book_id WHERE r.id = ?`, requestID).
		Scan(&selection.BookID, &selection.RequestUpdatedAt, &selection.BookUpdatedAt, &bookTitle, &bookPath, &reservation); err != nil {
		return Plan{}, ErrStoredValue
	}
	if !utf8.ValidString(bookTitle.String) || !utf8.ValidString(bookPath.String) {
		return Plan{}, ErrStoredValue
	}
	selection.BookTitle = bookTitle.String
	if err := readResult(ctx, tx, &selection); err != nil {
		return Plan{}, err
	}
	if row.status == completedRequest {
		return completedPlan(ctx, tx, selection, bookPath)
	}
	if row.status != searchingStatus || row.claimedAt.Valid {
		return Plan{}, ErrNotSelectable
	}
	if err := selectable(selection); err != nil {
		return Plan{}, err
	}
	if strings.Trim(bookPath.String, " ") != "" || reservation.Valid {
		return Plan{}, ErrBookAcquired
	}
	var blocking int64
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM downloads WHERE request_id = ? AND (status <> ? OR typeof(status) <> 'integer' OR COALESCE(`+directRecoveryFields+`) IS NOT NULL)`,
		requestID, failedDownload).Scan(&blocking); err != nil {
		return Plan{}, err
	}
	if blocking > 0 {
		return Plan{}, ErrDownloadsActive
	}
	return Plan{Selection: selection}, nil
}

func completedPlan(ctx context.Context, tx *sql.Tx, selection Selection, bookPath sql.NullString) (Plan, error) {
	if bookPath.String != selection.BookPath() {
		return Plan{}, ErrNotSelectable
	}
	var downloadID int64
	err := tx.QueryRowContext(ctx, `SELECT id FROM downloads WHERE request_id = ? AND search_result_id = ? AND status = ? AND download_type = 'direct' AND download_path = ?
		ORDER BY id LIMIT 1`, selection.RequestID, selection.ResultID, completedDownload, selection.BookPath()).Scan(&downloadID)
	if errors.Is(err, sql.ErrNoRows) {
		return Plan{}, ErrNotSelectable
	}
	if err != nil {
		return Plan{}, err
	}
	return Plan{Selection: selection, Completed: downloadID}, nil
}

func readResult(ctx context.Context, tx *sql.Tx, selection *Selection) error {
	var requestID, status sql.NullInt64
	var guid, source, link, blocklisted, updatedAt sql.NullString
	var provider sql.NullInt64
	err := tx.QueryRowContext(ctx, `SELECT request_id, guid, title, source, status, blocklisted_at, download_url, size_bytes, acquisition_provider_id, updated_at
		FROM search_results WHERE id = ?`, selection.ResultID).
		Scan(&requestID, &guid, &selection.ResultTitle, &source, &status, &blocklisted, &link, &selection.ResultSize, &provider, &updatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrResultMissing
	}
	if err != nil {
		return ErrStoredValue
	}
	if requestID.Int64 != selection.RequestID {
		return ErrResultMissing
	}
	for _, text := range []string{guid.String, selection.ResultTitle.String, source.String, link.String} {
		if !utf8.ValidString(text) {
			return ErrStoredValue
		}
	}
	match := gutenbergGUID.FindStringSubmatch(guid.String)
	if source.String != gutenbergSource || match == nil || provider.Valid || blocklisted.Valid || !status.Valid {
		return ErrResultNotSelectable
	}
	selection.ResultUpdatedAt = updatedAt.String
	selection.ResultStatus = status.Int64
	selection.DownloadURL = link.String
	selection.Folders = [2]string{LibraryFolder, "book-" + strconv.FormatInt(selection.BookID, 10)}
	selection.Name = "gutenberg-" + match[1] + ".epub"
	return nil
}

func selectable(selection Selection) error {
	if selection.ResultStatus != pendingResult {
		return ErrResultNotSelectable
	}
	authorized, ok := selection.Origin.Authorize(selection.DownloadURL)
	if !ok || authorized != selection.DownloadURL {
		return ErrResultOffOrigin
	}
	if ebookExtension(selection.DownloadURL) != "epub" {
		return ErrResultNotEPUB
	}
	return nil
}

func ebookExtension(link string) string {
	parsed, err := url.Parse(link)
	if err != nil {
		return ""
	}
	segments := strings.Split(strings.ToLower(path.Base(parsed.Path)), ".")
	for index := len(segments) - 1; index >= 1; index-- {
		if extension, known := ebookExtensions[segments[index]]; known {
			return extension
		}
	}
	return ""
}

func libraryRoot(stored settings) (string, error) {
	root, isText := stored.text("ebook_output_path", defaultEbookRoot)
	if !isText || !stored["ebook_output_path"].stored {
		return "", ErrLibraryRoot
	}
	switch {
	case stored.present("audiobookshelf_url", "") && stored.present("audiobookshelf_api_key", ""),
		stored.present("bookorbit_url", "") && stored.present("bookorbit_username", "") && stored.present("bookorbit_password", ""),
		stored.present("grimmory_url", "") && stored.present("grimmory_username", "") && stored.present("grimmory_password", ""):
		return "", ErrLibraryScan
	case stored.present("library_import_file_mode", ""), stored.present("library_import_folder_mode", ""):
		return "", ErrImportPermissions
	}
	return root, nil
}

func verifyColumns(ctx context.Context, tx *sql.Tx, required map[string][]string) error {
	for table, columns := range required {
		present := map[string]bool{}
		rows, err := tx.QueryContext(ctx, `SELECT name FROM pragma_table_info(?)`, table)
		if err != nil {
			return err
		}
		for rows.Next() {
			var name string
			if err := rows.Scan(&name); err != nil {
				rows.Close()
				return err
			}
			present[name] = true
		}
		if err := rows.Close(); err != nil {
			return err
		}
		for _, column := range columns {
			if !present[column] {
				return ErrSchemaUnsupported
			}
		}
	}
	return nil
}

func Referenced(ctx context.Context, store *wfstore.Store, bookPath string) (bool, error) {
	var count int64
	if err := store.DB().QueryRowContext(ctx, `SELECT COUNT(*) FROM books WHERE file_path = ?`, bookPath).Scan(&count); err != nil {
		return false, wfstore.Wrap(err)
	}
	return count > 0, nil
}

type Authorize func(ctx context.Context, tx *sql.Tx) error

func Complete(ctx context.Context, store *wfstore.Store, selection Selection, authorize Authorize, verify func() error, now time.Time) (int64, error) {
	var downloadID int64
	err := store.Transact(ctx, func(tx *sql.Tx) error {
		current, err := planIn(ctx, tx, selection.RequestID, selection.ResultID)
		if err != nil && SelectionRefusal(err) == nil {
			return err
		}
		if err != nil || current.Completed != 0 || current.Selection != selection {
			return ErrSuperseded
		}
		if authorize != nil {
			if err := authorize(ctx, tx); err != nil {
				return err
			}
		}
		downloadID, err = writeCompletion(ctx, tx, selection, wfstore.FormatTimestamp(now))
		if err != nil {
			return err
		}
		if err := fault.Hit(ctx, "download.before-commit"); err != nil {
			return err
		}
		return verify()
	})
	return downloadID, err
}

func writeCompletion(ctx context.Context, tx *sql.Tx, selection Selection, stamp string) (int64, error) {
	statements := []struct {
		query     string
		arguments []any
	}{
		{`UPDATE search_results SET status = ? WHERE request_id = ? AND id <> ?`, []any{rejectedStatus, selection.RequestID, selection.ResultID}},
		{`UPDATE search_results SET status = ?, updated_at = ? WHERE id = ?`, []any{selectedResult, stamp, selection.ResultID}},
	}
	for _, statement := range statements {
		if _, err := tx.ExecContext(ctx, statement.query, statement.arguments...); err != nil {
			return 0, err
		}
	}
	inserted, err := tx.ExecContext(ctx, `INSERT INTO downloads (request_id, search_result_id, name, size_bytes, status, download_type, download_path, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, 'direct', ?, ?, ?)`, selection.RequestID, selection.ResultID, selection.ResultTitle, selection.ResultSize, completedDownload, selection.BookPath(), stamp, stamp)
	if err != nil {
		return 0, err
	}
	downloadID, err := inserted.LastInsertId()
	if err != nil {
		return 0, err
	}
	queued := map[string]any{"search_result_id": selection.ResultID, "trigger": "manual_select"}
	if selection.ResultTitle.Valid {
		queued["title"] = selection.ResultTitle.String
	}
	queuedDetails, err := json.Marshal(queued)
	if err != nil {
		return 0, err
	}
	events := []struct{ kind, source, message, details string }{
		{"download_queued", "request", queuedMessage, string(queuedDetails)},
		{"dispatch_started", "DownloadJob", dispatchMessage, `{"request_status":"downloading"}`},
		{"completed", "DownloadJob", completedMessage, `{}`},
	}
	for _, event := range events {
		if _, err := tx.ExecContext(ctx, `INSERT INTO request_events (request_id, download_id, event_type, source, message, level, details, user_visible, created_at, updated_at)
			VALUES (?, ?, ?, ?, ?, 0, ?, 0, ?, ?)`, selection.RequestID, downloadID, event.kind, event.source, event.message, event.details, stamp, stamp); err != nil {
			return 0, err
		}
	}
	writes := []struct {
		query     string
		arguments []any
	}{
		{`UPDATE books SET file_path = ?, reference_target_roots = NULL, updated_at = ? WHERE id = ?`, []any{selection.BookPath(), stamp, selection.BookID}},
		{`UPDATE requests SET status = ?, completed_at = ?, attention_needed = 0, issue_description = NULL, next_retry_at = NULL, search_claimed_at = NULL, updated_at = ? WHERE id = ?`,
			[]any{completedRequest, stamp, stamp, selection.RequestID}},
		{`INSERT INTO activity_logs (action, user_id, trackable_type, trackable_id, details, created_at, updated_at) VALUES (?, ?, 'Request', ?, '{}', ?, ?)`,
			[]any{activityCompleted, selection.UserID, selection.RequestID, stamp, stamp}},
		{`INSERT INTO notifications (user_id, notifiable_type, notifiable_id, notification_type, title, message, created_at, updated_at) VALUES (?, 'Request', ?, 'request_completed', 'Book Ready', ?, ?, ?)`,
			[]any{selection.UserID, selection.RequestID, `"` + selection.BookTitle + `" is now available for download.`, stamp, stamp}},
	}
	for _, write := range writes {
		if _, err := tx.ExecContext(ctx, write.query, write.arguments...); err != nil {
			return 0, err
		}
	}
	return downloadID, nil
}
