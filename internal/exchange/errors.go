package exchange

import "fmt"

const (
	CodeInvalidRequest    = "INVALID_REQUEST"
	CodeRecipientConflict = "RECIPIENT_CONFLICT"
	CodeUserNotFound      = "USER_NOT_FOUND"
	CodeGroupNotFound     = "GROUP_NOT_FOUND"
	CodeExchangeFailure   = "EXCHANGE_COMMAND_FAILED"
	CodeAutomationFailure = "AUTOMATION_UNAVAILABLE"
)

type OperationError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
	Cause   error  `json:"-"`
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

func newOperationError(code, message string, cause error) *OperationError {
	if code == "" {
		code = CodeExchangeFailure
	}
	if message == "" {
		message = "Exchange operation failed"
	}
	return &OperationError{Code: code, Message: message, Cause: cause}
}
