// Package direct connects to the restricted Exchange endpoint without a Windows shell.
package direct

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/m15608293998-arch/exchange-automation/internal/automation"
)

type Connection struct {
	URL            string `json:"url"`
	Auth           string `json:"auth"`
	Username       string `json:"username,omitempty"`
	Password       string `json:"password,omitempty"`
	CredentialFile string `json:"credential_file,omitempty"`
}

// Validate deliberately offers no certificate bypass, Basic auth or automatic fallback.
func (c Connection) Validate() error {
	u, err := url.Parse(c.URL)
	if err != nil || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" ||
		(u.Scheme != "http" && u.Scheme != "https") || (u.Path != "/PowerShell/" && u.Path != "/PowerShell") {
		return errors.New("EXCHANGE_POWERSHELL_URL must be http(s)://server-fqdn/PowerShell/ without credentials or query")
	}
	if net.ParseIP(u.Hostname()) != nil || !strings.Contains(u.Hostname(), ".") {
		return errors.New("EXCHANGE_POWERSHELL_URL requires a DNS FQDN, not an IP or short name")
	}
	if u.Port() != "" {
		port, err := strconv.Atoi(u.Port())
		if err != nil || port < 1 || port > 65535 {
			return errors.New("invalid Exchange endpoint port")
		}
	}
	if c.Auth != "kerberos" && c.Auth != "ntlm" {
		return errors.New("EXCHANGE_AUTH must be kerberos or ntlm; no automatic downgrade")
	}
	if c.Auth == "ntlm" && u.Scheme != "https" {
		return errors.New("NTLM requires HTTPS with a trusted server certificate")
	}
	if c.CredentialFile != "" {
		if c.Username != "" || c.Password != "" {
			return errors.New("use EXCHANGE_CREDENTIAL_FILE or EXCHANGE_USERNAME/EXCHANGE_PASSWORD, not both")
		}
	} else if strings.TrimSpace(c.Username) == "" || c.Password == "" || strings.Contains(c.Password, "replace-with-") {
		return errors.New("configure EXCHANGE_CREDENTIAL_FILE or EXCHANGE_USERNAME and EXCHANGE_PASSWORD")
	}
	return nil
}

type Runner struct {
	binary, script string
	connection     Connection
}

func NewRunner(binary, script string, connection Connection) (*Runner, error) {
	if strings.TrimSpace(binary) == "" || strings.TrimSpace(script) == "" {
		return nil, errors.New("direct runner requires Python binary and worker script")
	}
	if err := connection.Validate(); err != nil {
		return nil, err
	}
	return &Runner{binary: binary, script: script, connection: connection}, nil
}

func (r *Runner) Execute(ctx context.Context, operation string, parameters map[string]any) (automation.Result, error) {
	switch operation {
	case "resolve_groups", "ensure_mailbox", "ensure_group_member", "discover_user_groups", "remove_group_member":
	default:
		return automation.Result{}, errors.New("unsupported direct Exchange operation")
	}
	payload, err := json.Marshal(struct {
		Connection Connection     `json:"connection"`
		Operation  string         `json:"operation"`
		Parameters map[string]any `json:"parameters"`
	}{r.connection, operation, parameters})
	if err != nil {
		return automation.Result{}, errors.New("cannot encode direct Exchange request")
	}
	// Secrets travel over stdin, not shell arguments or temporary request files.
	command := exec.CommandContext(ctx, r.binary, "-B", r.script)
	command.Stdin = bytes.NewReader(payload)
	for _, value := range os.Environ() {
		name, _, _ := strings.Cut(value, "=")
		if name != "API_TOKEN" && name != "EXCHANGE_PASSWORD" && name != "EXCHANGE_WINRM_PASSWORD" {
			command.Env = append(command.Env, value)
		}
	}
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.Cancel = func() error {
		err := syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
		if errors.Is(err, syscall.ESRCH) {
			return os.ErrProcessDone
		}
		return err
	}
	command.WaitDelay = 2 * time.Second
	output := &limitedOutput{}
	command.Stdout = output
	// Never expose Python/PSRP exceptions: they may contain bound passwords.
	command.Stderr = io.Discard
	err = command.Run()
	if command.Process != nil {
		_ = syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
	}
	if ctx.Err() != nil {
		return automation.Result{}, fmt.Errorf("direct Exchange worker interrupted: %w", ctx.Err())
	}
	if err != nil || output.overflow {
		return automation.Result{}, errors.New("direct Exchange worker failed or exceeded output limit")
	}
	var envelope struct {
		OK *bool `json:"ok"`
	}
	var result automation.Result
	if json.Unmarshal(output.Bytes(), &envelope) != nil || envelope.OK == nil ||
		json.Unmarshal(output.Bytes(), &result) != nil || (!result.OK && (result.Code == "" || result.Message == "")) {
		return automation.Result{}, errors.New("invalid direct Exchange result")
	}
	return result, nil
}

type limitedOutput struct {
	buffer   bytes.Buffer
	overflow bool
}

func (b *limitedOutput) Bytes() []byte { return b.buffer.Bytes() }

func (b *limitedOutput) Write(p []byte) (int, error) {
	n := len(p)
	if remaining := 4*1024*1024 - b.buffer.Len(); len(p) > remaining {
		b.overflow = true
		p = p[:remaining]
	}
	_, _ = b.buffer.Write(p)
	return n, nil
}
