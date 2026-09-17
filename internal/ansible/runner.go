package ansible

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strings"

	"github.com/m15608293998-arch/exchange-automation/internal/automation"
)

var (
	ErrExecution = errors.New("ansible execution failed")
	resultRE     = regexp.MustCompile(`EXCHANGE_AUTOMATION_RESULT_B64=([A-Za-z0-9+/=]+)`)
	operations   = map[string]struct{}{
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
	if err := os.Chmod(r.localTemp, 0o700); err != nil {
		return automation.Result{}, fmt.Errorf("secure Ansible temp directory: %w", err)
	}

	varsFile, err := os.CreateTemp(r.localTemp, "exchange-vars-*.json")
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
		Operation:  operation,
		Parameters: parameters,
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
		"ANSIBLE_LOCAL_TEMP": r.localTemp,
		"ANSIBLE_NOCOLOR":    "1",
	})

	output, commandErr := command.CombinedOutput()
	result, parseErr := parseResult(output)
	if parseErr == nil {
		return result, nil
	}

	if ctxErr := ctx.Err(); ctxErr != nil {
		return automation.Result{}, fmt.Errorf("%w: %w", ErrExecution, ctxErr)
	}
	if commandErr != nil {
		return automation.Result{}, fmt.Errorf("%w: %v", ErrExecution, commandErr)
	}
	return automation.Result{}, fmt.Errorf("%w: Ansible returned no structured result", ErrExecution)
}

func parseResult(output []byte) (automation.Result, error) {
	matches := resultRE.FindAllSubmatch(output, -1)
	if len(matches) == 0 {
		return automation.Result{}, errors.New("structured result marker not found")
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
	return result, nil
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
