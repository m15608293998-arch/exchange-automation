package exchange

import (
	"errors"
	"fmt"
)

const (
	CodeInvalidRequest    = "INVALID_REQUEST"
	CodeRecipientConflict = "RECIPIENT_CONFLICT"
	CodeUserNotFound      = "USER_NOT_FOUND"
	CodeGroupNotFound     = "GROUP_NOT_FOUND"
	CodeExchangeFailure   = "EXCHANGE_COMMAND_FAILED"
	CodeAutomationFailure = "AUTOMATION_UNAVAILABLE"
	CodeGroupType         = "GROUP_TYPE_NOT_ALLOWED"
	CodeOperationBusy     = "OPERATION_BUSY"
	CodeCapacity          = "CAPACITY_EXCEEDED"
	CodeStateUnknown      = "OPERATION_STATE_UNKNOWN"
)

type OperationError struct {
	Code         string `json:"code"`
	Message      string `json:"message"`
	Cause        error  `json:"-"`
	Step         string `json:"step,omitempty"`
	Target       string `json:"target,omitempty"`
	StateUnknown bool   `json:"state_unknown"`
}

func (e *OperationError) Error() string {
	if e.Cause == nil {
		return fmt.Sprintf("%s: %s", e.Code, e.Message)
	}
	return fmt.Sprintf("%s: %s: %v", e.Code, e.Message, e.Cause)
}

func (e *OperationError) Unwrap() error {
	return e.Cause
}

func operationStateUnknown(err error) bool {
	var operationErr *OperationError
	return errors.As(err, &operationErr) && operationErr.StateUnknown
}

func withTarget(err error, target string) error {
	var operationErr *OperationError
	if errors.As(err, &operationErr) {
		operationErr.Target = target
	}
	return err
}

func newOperationError(code, message string, cause error) *OperationError {
	if code == "" {
		code = CodeExchangeFailure
	}
	if message == "" {
		message = "Exchange operation failed"
	}
	return &OperationError{Code: code, Message: message, Cause: cause}
}
