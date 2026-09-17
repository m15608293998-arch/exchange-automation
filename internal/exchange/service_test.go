package exchange

import (
	"context"
	"encoding/json"
	"errors"
	"reflect"
	"testing"

	"github.com/m15608293998-arch/exchange-automation/internal/automation"
)

type executorCall struct {
	operation  string
	parameters map[string]any
}

type executorResponse struct {
	result automation.Result
	err    error
}

type fakeExecutor struct {
	calls     []executorCall
	responses []executorResponse
}

func (f *fakeExecutor) Execute(_ context.Context, operation string, parameters map[string]any) (automation.Result, error) {
	f.calls = append(f.calls, executorCall{operation: operation, parameters: parameters})
	if len(f.responses) == 0 {
		return automation.Result{}, errors.New("unexpected executor call")
	}
	response := f.responses[0]
	f.responses = f.responses[1:]
	return response.result, response.err
}

func TestOnboardCreatesMailboxAndAddsGroups(t *testing.T) {
	t.Parallel()

	executor := &fakeExecutor{responses: []executorResponse{
		{result: successfulResult(map[string]any{
			"created": true, "login_name": "slpeng", "display_name": "江流", "primary_smtp_address": "slpeng@bjwgby.com",
		})},
		{result: successfulResult(map[string]any{"group": "all@bjwgby.com", "added": true})},
		{result: successfulResult(map[string]any{"group": "dev@bjwgby.com", "added": false})},
	}}
	service := newTestService(t, executor)

	result, err := service.Onboard(context.Background(), OnboardInput{
		LoginName: "SLPeng", DisplayName: "江流", InitialPassword: "test-password", Groups: []string{"all", "dev", "ALL"},
	})
	if err != nil {
		t.Fatalf("Onboard() error = %v", err)
	}
	if !result.Created {
		t.Fatal("Onboard() Created = false, want true")
	}
	if !reflect.DeepEqual(result.AddedGroups, []string{"all@bjwgby.com"}) {
		t.Fatalf("Onboard() AddedGroups = %#v", result.AddedGroups)
	}
	if !reflect.DeepEqual(result.ExistingGroups, []string{"dev@bjwgby.com"}) {
		t.Fatalf("Onboard() ExistingGroups = %#v", result.ExistingGroups)
	}
	if len(executor.calls) != 3 {
		t.Fatalf("executor calls = %d, want 3", len(executor.calls))
	}
	if executor.calls[0].operation != "ensure_mailbox" {
		t.Fatalf("first operation = %q", executor.calls[0].operation)
	}
	if got := executor.calls[0].parameters["UserPrincipalName"]; got != "slpeng@bjwgby.com" {
		t.Fatalf("UserPrincipalName = %#v", got)
	}
	if got := executor.calls[0].parameters["InitialPassword"]; got != "test-password" {
		t.Fatalf("InitialPassword was not passed to Ansible")
	}
}

func TestOnboardRejectsInvalidInputWithoutExecution(t *testing.T) {
	t.Parallel()

	executor := &fakeExecutor{}
	service := newTestService(t, executor)

	_, err := service.Onboard(context.Background(), OnboardInput{
		LoginName: "bad@login", DisplayName: "Test", InitialPassword: "password",
	})
	assertOperationErrorCode(t, err, CodeInvalidRequest)
	if len(executor.calls) != 0 {
		t.Fatalf("executor calls = %d, want 0", len(executor.calls))
	}
}

func TestOnboardReturnsPartialResultAfterGroupFailure(t *testing.T) {
	t.Parallel()

	executor := &fakeExecutor{responses: []executorResponse{
		{result: successfulResult(map[string]any{
			"created": true, "login_name": "slpeng", "primary_smtp_address": "slpeng@bjwgby.com",
		})},
		{result: successfulResult(map[string]any{"group": "all@bjwgby.com", "added": true})},
		{result: automation.Result{OK: false, Code: CodeGroupNotFound, Message: "Distribution group was not found"}},
	}}
	service := newTestService(t, executor)

	result, err := service.Onboard(context.Background(), OnboardInput{
		LoginName: "slpeng", DisplayName: "江流", InitialPassword: "password", Groups: []string{"all", "missing"},
	})
	assertOperationErrorCode(t, err, CodeGroupNotFound)
	if !reflect.DeepEqual(result.AddedGroups, []string{"all@bjwgby.com"}) {
		t.Fatalf("partial AddedGroups = %#v", result.AddedGroups)
	}
}

func TestOffboardRemovesDiscoveredGroups(t *testing.T) {
	t.Parallel()

	executor := &fakeExecutor{responses: []executorResponse{
		{result: successfulResult(map[string]any{"groups": []map[string]string{
			{"identity": "group-b", "label": "b@bjwgby.com"},
			{"identity": "group-a", "label": "a@bjwgby.com"},
		}})},
		{result: successfulResult(map[string]any{"group": "b@bjwgby.com", "removed": true})},
		{result: successfulResult(map[string]any{"group": "a@bjwgby.com", "removed": true})},
	}}
	service := newTestService(t, executor)

	result, err := service.Offboard(context.Background(), "SLPeng")
	if err != nil {
		t.Fatalf("Offboard() error = %v", err)
	}
	if !reflect.DeepEqual(result.RemovedGroups, []string{"a@bjwgby.com", "b@bjwgby.com"}) {
		t.Fatalf("RemovedGroups = %#v", result.RemovedGroups)
	}
	if len(executor.calls) != 3 {
		t.Fatalf("executor calls = %d, want 3", len(executor.calls))
	}
}

func TestOffboardIsIdempotentWhenNoGroupsRemain(t *testing.T) {
	t.Parallel()

	executor := &fakeExecutor{responses: []executorResponse{
		{result: successfulResult(map[string]any{"groups": []map[string]string{}})},
	}}
	service := newTestService(t, executor)

	result, err := service.Offboard(context.Background(), "slpeng")
	if err != nil {
		t.Fatalf("Offboard() error = %v", err)
	}
	if result.RemovedGroups == nil || len(result.RemovedGroups) != 0 {
		t.Fatalf("RemovedGroups = %#v, want empty non-nil list", result.RemovedGroups)
	}
}

func newTestService(t *testing.T, executor automation.Executor) *Service {
	t.Helper()
	service, err := NewService(executor, Config{
		MailDomain:              "bjwgby.com",
		BypassGroupManagerCheck: true,
	})
	if err != nil {
		t.Fatalf("NewService() error = %v", err)
	}
	return service
}

func successfulResult(data any) automation.Result {
	encoded, err := json.Marshal(data)
	if err != nil {
		panic(err)
	}
	return automation.Result{OK: true, Data: encoded}
}

func assertOperationErrorCode(t *testing.T, err error, code string) {
	t.Helper()
	var operationErr *OperationError
	if !errors.As(err, &operationErr) {
		t.Fatalf("error = %v, want *OperationError", err)
	}
	if operationErr.Code != code {
		t.Fatalf("error code = %q, want %q", operationErr.Code, code)
	}
}
