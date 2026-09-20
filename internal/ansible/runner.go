package ansible

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/m15608293998-arch/exchange-automation/internal/automation"
)

var (
	ErrExecution = errors.New("ansible execution failed")
	resultRE     = regexp.MustCompile(`EXCHANGE_AUTOMATION_RESULT_B64=([A-Za-z0-9+/=]+)`)
	operations   = map[string]struct{}{
		"resolve_groups":       {},
		"ensure_mailbox":       {},
		"ensure_group_member":  {},
		"discover_user_groups": {},
		"remove_group_member":  {},
	}
)

type Runner struct {
	binary    string
	inventory string
	playbook  string
	localTemp string
}

func NewRunner(binary, inventory, playbook, localTemp string) (*Runner, error) {
	if strings.TrimSpace(binary) == "" {
		return nil, fmt.Errorf("ansible-playbook binary must not be empty")
	}
	if strings.TrimSpace(inventory) == "" {
		return nil, fmt.Errorf("Ansible inventory must not be empty")
	}
	if strings.TrimSpace(playbook) == "" {
		return nil, fmt.Errorf("Ansible playbook must not be empty")
	}
	if strings.TrimSpace(localTemp) == "" {
		return nil, fmt.Errorf("Ansible local temp directory must not be empty")
	}

	return &Runner{
		binary:    binary,
		inventory: inventory,
		playbook:  playbook,
		localTemp: localTemp,
	}, nil
}

func (r *Runner) Execute(ctx context.Context, operation string, parameters map[string]any) (automation.Result, error) {
	if _, allowed := operations[operation]; !allowed {
		return automation.Result{}, fmt.Errorf("unsupported Exchange operation %q", operation)
	}

	if err := os.MkdirAll(r.localTemp, 0o700); err != nil {
		return automation.Result{}, fmt.Errorf("create Ansible temp directory: %w", err)
	}
	info, err := os.Lstat(r.localTemp)
	if err != nil || !info.IsDir() || info.Mode().Perm()&0o077 != 0 {
		return automation.Result{}, fmt.Errorf("Ansible temp directory must be a private directory (0700)")
	}
	runDir, err := os.MkdirTemp(r.localTemp, "run-")
	if err != nil {
		return automation.Result{}, fmt.Errorf("create run directory: %w", err)
	}
	defer os.RemoveAll(runDir)
	varsFile, err := os.CreateTemp(runDir, "exchange-vars-*.json")
	if err != nil {
		return automation.Result{}, fmt.Errorf("create temporary Ansible variables file: %w", err)
	}
	varsPath := varsFile.Name()
	defer func() {
		_ = os.Remove(varsPath)
	}()

	if err := varsFile.Chmod(0o600); err != nil {
		_ = varsFile.Close()
		return automation.Result{}, fmt.Errorf("secure temporary Ansible variables file: %w", err)
	}

	payload := struct {
		Operation  string         `json:"exchange_operation"`
		Parameters map[string]any `json:"exchange_parameters"`
	}{
		Operation: operation,
		// Ansible 2.15's JSON decoder recognizes this unsafe string envelope.
		// Protect before templating, including passwords and nested list values.
		Parameters: protectValues(parameters).(map[string]any),
	}
	if err := json.NewEncoder(varsFile).Encode(payload); err != nil {
		_ = varsFile.Close()
		return automation.Result{}, fmt.Errorf("write temporary Ansible variables file: %w", err)
	}
	if err := varsFile.Close(); err != nil {
		return automation.Result{}, fmt.Errorf("close temporary Ansible variables file: %w", err)
	}

	command := exec.CommandContext(
		ctx,
		r.binary,
		"--inventory", r.inventory,
		r.playbook,
		"--extra-vars", "@"+varsPath,
	)
	command.Env = withEnvironment(os.Environ(), map[string]string{
		"ANSIBLE_LOCAL_TEMP":      runDir,
		"ANSIBLE_NOCOLOR":         "1",
		"ANSIBLE_STDOUT_CALLBACK": "default",
	})
	// Linux controller: cancel the whole process group, not just ansible's parent.
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
	command.Stdout, command.Stderr = output, output
	commandErr := command.Run()
	if command.Process != nil {
		_ = syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
	}
	if ctxErr := ctx.Err(); ctxErr != nil {
		return automation.Result{}, fmt.Errorf("%w: %w", ErrExecution, ctxErr)
	}
	if commandErr != nil {
		return automation.Result{}, fmt.Errorf("%w: %v", ErrExecution, commandErr)
	}
	if output.overflow {
		return automation.Result{}, fmt.Errorf("%w: output limit exceeded", ErrExecution)
	}
	result, parseErr := parseResult(output.Bytes())
	if parseErr != nil {
		return automation.Result{}, fmt.Errorf("%w: invalid structured result", ErrExecution)
	}
	return result, nil
}

func parseResult(output []byte) (automation.Result, error) {
	matches := resultRE.FindAllSubmatch(output, -1)
	if len(matches) != 1 {
		return automation.Result{}, errors.New("expected exactly one structured result marker")
	}

	encoded := matches[len(matches)-1][1]
	decoded, err := base64.StdEncoding.DecodeString(string(encoded))
	if err != nil {
		return automation.Result{}, fmt.Errorf("decode structured result: %w", err)
	}

	var result automation.Result
	if err := json.Unmarshal(decoded, &result); err != nil {
		return automation.Result{}, fmt.Errorf("decode structured result JSON: %w", err)
	}
	var envelope struct {
		OK *bool `json:"ok"`
	}
	if err := json.Unmarshal(decoded, &envelope); err != nil || envelope.OK == nil {
		return automation.Result{}, errors.New("missing result status")
	}
	if !result.OK && (result.Code == "" || result.Message == "") {
		return automation.Result{}, errors.New("missing error details")
	}
	return result, nil
}

func protectValues(value any) any {
	switch v := value.(type) {
	case string:
		return map[string]string{"__ansible_unsafe": v}
	case []string:
		out := make([]any, len(v))
		for i, item := range v {
			out[i] = protectValues(item)
		}
		return out
	case []any:
		out := make([]any, len(v))
		for i, item := range v {
			out[i] = protectValues(item)
		}
		return out
	case map[string]any:
		out := make(map[string]any, len(v))
		for key, item := range v {
			out[key] = protectValues(item)
		}
		return out
	default:
		return value
	}
}

type limitedOutput struct {
	bytes.Buffer
	mu       sync.Mutex
	overflow bool
}

func (b *limitedOutput) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	const limit = 4 << 20
	n := len(p)
	if n > limit-b.Len() {
		b.overflow = true
		p = p[:limit-b.Len()]
	}
	_, _ = b.Buffer.Write(p)
	return n, nil
}

func withEnvironment(current []string, overrides map[string]string) []string {
	result := make([]string, 0, len(current)+len(overrides))
	for _, entry := range current {
		name, _, found := strings.Cut(entry, "=")
		if found {
			if _, overridden := overrides[name]; overridden {
				continue
			}
		}
		result = append(result, entry)
	}
	for name, value := range overrides {
		result = append(result, name+"="+value)
	}
	return result
}
