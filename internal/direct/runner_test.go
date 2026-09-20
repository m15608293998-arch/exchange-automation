package direct

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func testConnection() Connection {
	return Connection{URL: "http://exchange.example.com/PowerShell/", Auth: "kerberos", Username: "svc@example.com", Password: "local-test-only"}
}

func TestConnectionPolicy(t *testing.T) {
	for _, endpoint := range []string{"", "http://192.0.2.1/PowerShell/", "http://exchange/PowerShell/", "http://exchange.example.com/wsman", "http://user:pass@exchange.example.com/PowerShell/", "http://exchange.example.com/PowerShell/?x=1", "http://exchange.example.com:0/PowerShell/"} {
		c := testConnection()
		c.URL = endpoint
		if c.Validate() == nil {
			t.Errorf("accepted endpoint %s", endpoint)
		}
	}
	for _, auth := range []string{"ntlm", "negotiate", "basic", "credssp", ""} {
		c := testConnection()
		c.Auth = auth
		if c.Validate() == nil {
			t.Errorf("accepted unsafe HTTP auth %s", auth)
		}
	}
	c := testConnection()
	c.Auth, c.URL = "ntlm", "https://exchange.example.com/PowerShell/"
	if err := c.Validate(); err != nil {
		t.Fatal(err)
	}
	c.CredentialFile = "/run/secrets/exchange.json"
	if c.Validate() == nil {
		t.Fatal("ambiguous credential sources accepted")
	}
	c.Username, c.Password = "", ""
	if err := c.Validate(); err != nil {
		t.Fatal(err)
	}
}

func worker(t *testing.T, script string) *Runner {
	t.Helper()
	python, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("python3 unavailable")
	}
	file := filepath.Join(t.TempDir(), "worker.py")
	if err := os.WriteFile(file, []byte(script), 0600); err != nil {
		t.Fatal(err)
	}
	runner, err := NewRunner(python, file, testConnection())
	if err != nil {
		t.Fatal(err)
	}
	return runner
}

func TestLiteralStdinNoSecretsInArgumentsOrEnvironment(t *testing.T) {
	t.Setenv("API_TOKEN", "must-not-inherit")
	t.Setenv("EXCHANGE_PASSWORD", "must-not-inherit")
	t.Setenv("EXCHANGE_WINRM_PASSWORD", "must-not-inherit")
	runner := worker(t, `import json,sys,os
r=json.load(sys.stdin)
assert len(sys.argv)==1
assert not any(k in os.environ for k in ('API_TOKEN','EXCHANGE_PASSWORD','EXCHANGE_WINRM_PASSWORD'))
assert r['connection']['password']=='local-test-only'
print(json.dumps({'ok':True,'data':r['parameters']}))
`)
	want := map[string]any{"InitialPassword": "{{7*7}};$nothing", "DisplayName": "$(echo nope)", "GroupIdentities": []any{"{{ lookup('pipe', 'false') }}"}}
	result, err := runner.Execute(context.Background(), "ensure_mailbox", want)
	if err != nil || !result.OK {
		t.Fatalf("execute: %v", err)
	}
	var got map[string]any
	if err := json.Unmarshal(result.Data, &got); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"InitialPassword", "DisplayName"} {
		if got[key] != want[key] {
			t.Fatalf("value was interpreted: %s", key)
		}
	}
}

func TestWorkerProtocolFailsClosed(t *testing.T) {
	for name, script := range map[string]string{
		"missing-status":      `print('{"data":{}}')`,
		"duplicate-result":    `print('{"ok":true}\n{"ok":true}')`,
		"nonzero":             `import sys; print('{"ok":true}'); sys.exit(1)`,
		"missing-error":       `print('{"ok":false}')`,
		"oversize":            `print('x'*(4*1024*1024+1))`,
		"oversize-valid-json": `import json; print(json.dumps({'ok':True,'data':{'padding':'x'*(4*1024*1024+1)}}))`,
		"secret-stderr":       `import sys; print('PRIVATE_PASSWORD',file=sys.stderr); sys.exit(1)`,
	} {
		t.Run(name, func(t *testing.T) {
			_, err := worker(t, script).Execute(context.Background(), "ensure_mailbox", nil)
			if err == nil || strings.Contains(err.Error(), "PRIVATE_PASSWORD") {
				t.Fatalf("unsafe protocol handling: %v", err)
			}
		})
	}
}

func TestTimeoutAndAllowlist(t *testing.T) {
	runner := worker(t, "import time\ntime.sleep(30)\n")
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	_, err := runner.Execute(ctx, "ensure_mailbox", nil)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("missing timeout: %v", err)
	}
	if _, err := runner.Execute(context.Background(), "Remove-Mailbox", nil); err == nil {
		t.Fatal("unlisted operation accepted")
	}
}
