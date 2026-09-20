package ansible

import (
	"context"
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseResult(t *testing.T) {
	t.Parallel()

	encoded := base64.StdEncoding.EncodeToString([]byte(`{"ok":true,"data":{"created":true}}`))
	output := []byte("ok: [exchange] => {\n    \"msg\": \"EXCHANGE_AUTOMATION_RESULT_B64=" + encoded + "\"\n}\n")

	result, err := parseResult(output)
	if err != nil {
		t.Fatalf("parseResult() error = %v", err)
	}
	if !result.OK {
		t.Fatal("parseResult() OK = false, want true")
	}
}

func TestParseResultRejectsMultipleMarkers(t *testing.T) {
	t.Parallel()

	first := base64.StdEncoding.EncodeToString([]byte(`{"ok":false,"code":"OLD"}`))
	last := base64.StdEncoding.EncodeToString([]byte(`{"ok":false,"code":"LATEST"}`))
	output := []byte("EXCHANGE_AUTOMATION_RESULT_B64=" + first + "\nEXCHANGE_AUTOMATION_RESULT_B64=" + last)

	if _, err := parseResult(output); err == nil {
		t.Fatal("multiple results must be rejected")
	}
}

func TestParseResultRejectsMissingMarker(t *testing.T) {
	t.Parallel()

	if _, err := parseResult([]byte("ordinary ansible output")); err == nil {
		t.Fatal("parseResult() error = nil, want error")
	}
}

func TestExecuteKeepsSecretOutOfArgumentsAndRemovesVariablesFile(t *testing.T) {
	t.Parallel()

	workingDirectory := t.TempDir()
	localTemp := filepath.Join(workingDirectory, "ansible-temp")
	fakeBinary := filepath.Join(workingDirectory, "fake-ansible-playbook")
	encoded := base64.StdEncoding.EncodeToString([]byte(`{"ok":true,"data":{"created":true}}`))
	script := strings.ReplaceAll(`#!/bin/sh
vars_file=""
for argument in "$@"; do
    case "$argument" in
        *secret-for-test*) exit 90 ;;
        @*) vars_file="${argument#@}" ;;
    esac
done
test -n "$vars_file" || exit 91
test "$(stat -c %a "$vars_file")" = "600" || exit 92
grep -q 'secret-for-test' "$vars_file" || exit 93
printf '%s\n' 'EXCHANGE_AUTOMATION_RESULT_B64=RESULT_TOKEN'
`, "RESULT_TOKEN", encoded)
	if err := os.WriteFile(fakeBinary, []byte(script), 0o700); err != nil {
		t.Fatalf("write fake ansible-playbook: %v", err)
	}

	runner, err := NewRunner(fakeBinary, "unused-inventory", "unused-playbook", localTemp)
	if err != nil {
		t.Fatalf("NewRunner() error = %v", err)
	}
	result, err := runner.Execute(context.Background(), "ensure_mailbox", map[string]any{
		"InitialPassword": "secret-for-test",
	})
	if err != nil {
		t.Fatalf("Execute() error = %v", err)
	}
	if !result.OK {
		t.Fatal("Execute() OK = false, want true")
	}

	entries, err := os.ReadDir(localTemp)
	if err != nil {
		t.Fatalf("read local temp directory: %v", err)
	}
	if len(entries) != 0 {
		t.Fatalf("temporary files remain after Execute(): %#v", entries)
	}
}
