package exchange

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/m15608293998-arch/exchange-automation/internal/automation"
)

func TestInvalidGroupPreventsAccountCreation(t *testing.T) {
	executor := &fakeExecutor{responses: []executorResponse{{result: automation.Result{OK: false, Code: CodeGroupNotFound, Message: "missing"}}}}
	result, err := newTestService(t, executor).Onboard(context.Background(), OnboardInput{LoginName: "slpeng", DisplayName: "江流", InitialPassword: "test", Groups: []string{"missing"}})
	assertOperationErrorCode(t, err, CodeGroupNotFound)
	if len(executor.calls) != 1 || executor.calls[0].operation != "resolve_groups" || result.MailboxID != "" {
		t.Fatal("created before preflight")
	}
}

func TestMalformedDiscoveryCannotReportSuccessfulCleanup(t *testing.T) {
	for _, payload := range []map[string]any{{}, {"mailbox_id": mailboxID}, {"mailbox_id": mailboxID, "groups": nil}, {"mailbox_id": "wrong", "groups": []any{}}} {
		executor := &fakeExecutor{responses: []executorResponse{{result: successfulResult(payload)}}}
		_, err := newTestService(t, executor).Offboard(context.Background(), "slpeng")
		assertOperationErrorCode(t, err, CodeAutomationFailure)
		if len(executor.calls) != 1 {
			t.Fatal("malformed discovery caused a write")
		}
	}
}

func TestOffboardUsesDiscoveredGUID(t *testing.T) {
	executor := &fakeExecutor{responses: []executorResponse{
		{result: successfulResult(map[string]any{"mailbox_id": mailboxID, "groups": []map[string]string{{"identity": groupA, "label": "all"}}})},
		{result: successfulResult(map[string]any{"group": "all", "group_id": groupA, "member_id": mailboxID, "removed": true})},
	}}
	_, err := newTestService(t, executor).Offboard(context.Background(), "slpeng")
	if err != nil {
		t.Fatal(err)
	}
	if executor.calls[1].parameters["MemberIdentity"] != mailboxID {
		t.Fatal("used mutable login instead of GUID")
	}
}

func TestExistingMailboxRetryDoesNotClaimPasswordApplied(t *testing.T) {
	executor := &fakeExecutor{responses: []executorResponse{{result: mailboxResult(false)}}}
	result, err := newTestService(t, executor).Onboard(context.Background(), OnboardInput{LoginName: "slpeng", DisplayName: "江流"})
	if err != nil {
		t.Fatal(err)
	}
	if result.Created || result.PasswordApplied {
		t.Fatal("retry claimed to set a password")
	}
}

func TestUncertainMutationSurvivesServiceRestart(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "state")
	executor := &fakeExecutor{responses: []executorResponse{{err: context.DeadlineExceeded}}}
	config := Config{MailDomain: "bjwgby.com", StateDirectory: directory}
	service, createErr := NewService(executor, config)
	if createErr != nil {
		t.Fatal(createErr)
	}
	input := OnboardInput{LoginName: "slpeng", DisplayName: "江流", InitialPassword: "test"}
	result, err := service.Onboard(context.Background(), input)
	if !errors.Is(err, context.DeadlineExceeded) || !operationStateUnknown(err) || result.MailboxID != "" {
		t.Fatalf("error=%v result=%+v", err, result)
	}
	if _, err := os.Stat(filepath.Join(directory, "slpeng.pending")); err != nil {
		t.Fatal(err)
	}
	restarted, createErr := NewService(executor, config)
	if createErr != nil {
		t.Fatal(createErr)
	}
	_, err = restarted.Offboard(context.Background(), "slpeng")
	assertOperationErrorCode(t, err, CodeStateUnknown)
	if len(executor.calls) != 1 {
		t.Fatal("unknown state allowed a second operation")
	}
}

func TestSuccessfulOperationClearsPendingRecord(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "state")
	executor := &fakeExecutor{responses: []executorResponse{{result: mailboxResult(true)}}}
	service, createErr := NewService(executor, Config{MailDomain: "bjwgby.com", StateDirectory: directory})
	if createErr != nil {
		t.Fatal(createErr)
	}
	_, err := service.Onboard(context.Background(), OnboardInput{LoginName: "slpeng", DisplayName: "江流", InitialPassword: "test"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(directory, "slpeng.pending")); !os.IsNotExist(err) {
		t.Fatal("pending record survived completed operation")
	}
}

type blockingExecutor struct {
	started chan struct{}
	release chan struct{}
}

func (e *blockingExecutor) Execute(ctx context.Context, _ string, _ map[string]any) (automation.Result, error) {
	close(e.started)
	select {
	case <-e.release:
		return mailboxResult(true), nil
	case <-ctx.Done():
		return automation.Result{}, ctx.Err()
	}
}
func TestConcurrentOnboardAndOffboardAreRejected(t *testing.T) {
	executor := &blockingExecutor{make(chan struct{}), make(chan struct{})}
	service, _ := NewService(executor, Config{MailDomain: "bjwgby.com", MaxConcurrentOperations: 1})
	finished := make(chan error, 1)
	go func() {
		_, err := service.Onboard(context.Background(), OnboardInput{LoginName: "slpeng", DisplayName: "江流", InitialPassword: "test"})
		finished <- err
	}()
	<-executor.started
	_, err := service.Offboard(context.Background(), "SLPENG")
	assertOperationErrorCode(t, err, CodeOperationBusy)
	_, err = service.Offboard(context.Background(), "someoneelse")
	assertOperationErrorCode(t, err, CodeCapacity)
	close(executor.release)
	if err := <-finished; err != nil {
		t.Fatal(err)
	}
}
