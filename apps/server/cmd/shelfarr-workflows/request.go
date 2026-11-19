package main

import (
	"context"
	"errors"
	"io"
	"os/signal"
	"regexp"
	"strconv"
	"syscall"
	"time"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/admission"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/fault"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/wfstore"
)

var accountPattern = regexp.MustCompile(`\A[1-9][0-9]{0,18}\z`)

var rejections = []error{
	admission.ErrInvalid,
	admission.ErrUnsupported,
	admission.ErrAccountUnavailable,
	admission.ErrSchemaUnsupported,
	admission.ErrStoredValue,
}

func parseAccount(text string) (int64, bool) {
	if !accountPattern.MatchString(text) {
		return 0, false
	}
	id, err := strconv.ParseInt(text, 10, 64)
	return id, err == nil
}

func admitRequest(workdir string, accountID int64, stdin io.Reader, out *reporter) int {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	body, err := io.ReadAll(io.LimitReader(stdin, admission.MaxBodyBytes+1))
	if err != nil {
		out.emit("error", map[string]any{"workflow": "request", "code": wfstore.CodeCancelled})
		return exitRecoverable
	}
	submission, err := admission.ParseSubmission(body)
	if err != nil {
		return reject(err, out)
	}
	store, code := openStore(ctx, workdir, 0, out)
	if store == nil {
		return code
	}
	defer store.Close()
	result, err := admission.Submit(ctx, store, accountID, submission, time.Now)
	if err != nil {
		for _, rejection := range rejections {
			if errors.Is(err, rejection) {
				return reject(rejection, out)
			}
		}
		fault.Observe(err)
		out.emit("error", map[string]any{"workflow": "request", "code": wfstore.CodeOf(err)})
		return exitRecoverable
	}
	out.emit("request", decision(result))
	return exitOK
}

func reject(err error, out *reporter) int {
	out.emit("rejected", map[string]any{"code": err.Error()})
	return exitRejected
}

func decision(result admission.Result) map[string]any {
	fields := map[string]any{"outcome": string(result.Outcome)}
	switch result.Outcome {
	case admission.Created:
		fields["request_id"] = strconv.FormatInt(result.RequestID, 10)
		fields["warnings"] = result.Warnings
	case admission.Existing:
		fields["request_id"] = strconv.FormatInt(result.RequestID, 10)
	case admission.AlreadyInLibrary:
		fields["publication_id"] = strconv.FormatInt(result.PublicationID, 10)
	}
	return fields
}
