package config

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	HTTPAddress              string
	MailDomain               string
	OrganizationalUnit       string
	MailboxDatabase          string
	ResetPasswordOnNextLogon bool
	BypassGroupManagerCheck  bool
	AnsiblePlaybookBinary    string
	AnsibleInventory         string
	AnsiblePlaybook          string
	AnsibleLocalTemp         string
	ExchangeOperationTimeout time.Duration
}

func Load() (Config, error) {
	resetPassword, err := envBool("EXCHANGE_RESET_PASSWORD_ON_NEXT_LOGON", false)
	if err != nil {
		return Config{}, err
	}

	bypassManagerCheck, err := envBool("EXCHANGE_BYPASS_GROUP_MANAGER_CHECK", true)
	if err != nil {
		return Config{}, err
	}

	operationTimeout, err := envDuration("EXCHANGE_OPERATION_TIMEOUT", 2*time.Minute)
	if err != nil {
		return Config{}, err
	}

	domain := strings.ToLower(strings.TrimSpace(envOrDefault("EXCHANGE_MAIL_DOMAIN", "bjwgby.com")))
	domain = strings.TrimPrefix(domain, "@")
	if domain == "" {
		return Config{}, fmt.Errorf("EXCHANGE_MAIL_DOMAIN must not be empty")
	}

	winRMUser := strings.TrimSpace(envOrDefault("EXCHANGE_WINRM_USER", "svc_exchange_auto@exchlab.local"))
	if winRMUser == "" {
		return Config{}, fmt.Errorf("EXCHANGE_WINRM_USER must not be empty")
	}

	_, passwordSet := os.LookupEnv("EXCHANGE_WINRM_PASSWORD")
	if !passwordSet || os.Getenv("EXCHANGE_WINRM_PASSWORD") == "" {
		return Config{}, fmt.Errorf("EXCHANGE_WINRM_PASSWORD must be set")
	}

	localTemp := envOrDefault("ANSIBLE_LOCAL_TEMP", filepath.Join(os.TempDir(), "exchange-automation-ansible"))

	return Config{
		HTTPAddress:              envOrDefault("HTTP_ADDRESS", "127.0.0.1:8080"),
		MailDomain:               domain,
		OrganizationalUnit:       strings.TrimSpace(os.Getenv("EXCHANGE_ORGANIZATIONAL_UNIT")),
		MailboxDatabase:          strings.TrimSpace(os.Getenv("EXCHANGE_MAILBOX_DATABASE")),
		ResetPasswordOnNextLogon: resetPassword,
		BypassGroupManagerCheck:  bypassManagerCheck,
		AnsiblePlaybookBinary:    envOrDefault("ANSIBLE_PLAYBOOK_BINARY", "ansible-playbook"),
		AnsibleInventory:         envOrDefault("ANSIBLE_INVENTORY", "automation/inventory/hosts.yml"),
		AnsiblePlaybook:          envOrDefault("ANSIBLE_PLAYBOOK", "automation/playbooks/exchange_operation.yml"),
		AnsibleLocalTemp:         localTemp,
		ExchangeOperationTimeout: operationTimeout,
	}, nil
}

func envOrDefault(name, fallback string) string {
	if value, ok := os.LookupEnv(name); ok && value != "" {
		return value
	}
	return fallback
}

func envBool(name string, fallback bool) (bool, error) {
	value, ok := os.LookupEnv(name)
	if !ok || strings.TrimSpace(value) == "" {
		return fallback, nil
	}

	parsed, err := strconv.ParseBool(value)
	if err != nil {
		return false, fmt.Errorf("%s must be a boolean: %w", name, err)
	}
	return parsed, nil
}

func envDuration(name string, fallback time.Duration) (time.Duration, error) {
	value, ok := os.LookupEnv(name)
	if !ok || strings.TrimSpace(value) == "" {
		return fallback, nil
	}

	parsed, err := time.ParseDuration(value)
	if err != nil {
		return 0, fmt.Errorf("%s must be a duration: %w", name, err)
	}
	if parsed <= 0 {
		return 0, fmt.Errorf("%s must be greater than zero", name)
	}
	return parsed, nil
}
