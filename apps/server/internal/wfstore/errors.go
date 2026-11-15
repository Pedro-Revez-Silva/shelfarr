package wfstore

import (
	"context"
	"errors"

	"modernc.org/sqlite"
)

const (
	CodeBusy          = "db-busy"
	CodeFenced        = "fenced"
	CodeCancelled     = "cancelled"
	CodeDatabase      = "db-error"
	CodeAlreadyOwned  = "already-owned"
	CodeNotDisposable = "not-disposable"
	CodeUsage         = "usage"
)

var (
	ErrFenced        = &Error{Code: CodeFenced}
	ErrAlreadyOwned  = &Error{Code: CodeAlreadyOwned}
	ErrNotDisposable = &Error{Code: CodeNotDisposable}
)

type Error struct {
	Code string
	Err  error
}

func (e *Error) Error() string { return e.Code }

func (e *Error) Unwrap() error { return e.Err }

func (e *Error) Is(target error) bool {
	other, ok := target.(*Error)
	return ok && other.Code == e.Code
}

func Fail(code string, cause error) *Error { return &Error{Code: code, Err: cause} }

func CodeOf(err error) string {
	var typed *Error
	switch {
	case err == nil:
		return ""
	case errors.As(err, &typed):
		return typed.Code
	case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		return CodeCancelled
	}
	return classify(err).Code
}

func classify(err error) *Error {
	var typed *Error
	if errors.As(err, &typed) {
		return typed
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return Fail(CodeCancelled, err)
	}
	var driver *sqlite.Error
	if errors.As(err, &driver) {
		switch driver.Code() & 0xff {
		case 5, 6:
			return Fail(CodeBusy, err)
		}
	}
	return Fail(CodeDatabase, err)
}

func Wrap(err error) error {
	if err == nil {
		return nil
	}
	return classify(err)
}
