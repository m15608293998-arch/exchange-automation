package ansible

import (
	"context"
	"encoding/base64"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestTimeoutKillsDescendantsAndCleansFiles(t *testing.T) {
	root := t.TempDir()
	binary := filepath.Join(root, "fake-playbook")
	if err := os.WriteFile(binary, []byte("#!/bin/sh\nsleep 10 &\nwait\n"), 0700); err != nil {
		t.Fatal(err)
	}
	temp := filepath.Join(root, "tmp")
	runner, _ := NewRunner(binary, "unused", "unused", temp)
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	started := time.Now()
	_, err := runner.Execute(ctx, "discover_user_groups", map[string]any{})
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("error: %v", err)
	}
	if time.Since(started) > 2*time.Second {
		t.Fatal("descendant output pipe blocked cancellation")
	}
	files, err := os.ReadDir(temp)
	if err != nil || len(files) != 0 {
		t.Fatal("run directory was not cleaned")
	}
}

func TestNonzeroExitCannotReportSuccess(t *testing.T) {
	binary := filepath.Join(t.TempDir(), "fake-playbook")
	marker := base64.StdEncoding.EncodeToString([]byte(`{"ok":true,"data":{"groups":[]}}`))
	script := "#!/bin/sh\nprintf '%s\\n' 'EXCHANGE_AUTOMATION_RESULT_B64=" + marker + "'\nexit 2\n"
	if err := os.WriteFile(binary, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	runner, _ := NewRunner(binary, "unused", "unused", filepath.Join(t.TempDir(), "tmp"))
	if _, err := runner.Execute(context.Background(), "discover_user_groups", map[string]any{}); err == nil {
		t.Fatal("failed process accepted")
	}
}

func TestResultRequiresExplicitStatusAndErrorDetails(t *testing.T) {
	for _, body := range []string{`{}`, `null`, `{"ok":false}`, `{"ok":null}`} {
		output := "EXCHANGE_AUTOMATION_RESULT_B64=" + base64.StdEncoding.EncodeToString([]byte(body))
		if _, err := parseResult([]byte(output)); err == nil {
			t.Fatalf("accepted %s", body)
		}
	}
}
