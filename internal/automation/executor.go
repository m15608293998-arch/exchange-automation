package automation

import (
	"context"
	"encoding/json"
)

// Executor runs one allow-listed Exchange operation on the target server.
type Executor interface {
	Execute(ctx context.Context, operation string, parameters map[string]any) (Result, error)
}

// Result is the small, stable protocol shared by PowerShell and Go.
type Result struct {
	OK      bool            `json:"ok"`
	Code    string          `json:"code,omitempty"`
	Message string          `json:"message,omitempty"`
	Data    json.RawMessage `json:"data,omitempty"`
}
