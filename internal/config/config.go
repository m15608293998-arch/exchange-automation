package config

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/m15608293998-arch/exchange-automation/internal/direct"
)

type Config struct {
	ConnectionMode           string
	DirectConnection         direct.Connection
	PythonBinary             string
	DirectWorker             string
	HTTPAddress              string
	APIToken                 string
	StateDirectory           string
	MailDomain               string
	UPNSuffix                string
	OrganizationalUnit       string
	MailboxDatabase          string
	DomainController         string
	ResetPasswordOnNextLogon bool
	BypassGroupManagerCheck  bool
	MaxConcurrentOperations  int
	AnsiblePlaybookBinary    string
	AnsibleInventory         string
	AnsiblePlaybook          string
	AnsibleLocalTemp         string
	ExchangeOperationTimeout time.Duration
}

func Load() (Config, error) {
	environment := envOrDefault("APP_ENV", "production")
	if environment != "production" && environment != "test" {
		return Config{}, fmt.Errorf("APP_ENV must be production or test")
	}
	mode := envOrDefault("EXCHANGE_CONNECTION_MODE", "direct")
	if mode != "direct" && mode != "ansible" {
		return Config{}, fmt.Errorf("EXCHANGE_CONNECTION_MODE must be direct or ansible")
	}
	connection := direct.Connection{
		URL: os.Getenv("EXCHANGE_POWERSHELL_URL"), Auth: envOrDefault("EXCHANGE_AUTH", "kerberos"),
		Username: os.Getenv("EXCHANGE_USERNAME"), Password: os.Getenv("EXCHANGE_PASSWORD"),
		CredentialFile: os.Getenv("EXCHANGE_CREDENTIAL_FILE"),
	}
	if mode == "direct" {
		if err := connection.Validate(); err != nil {
			return Config{}, err
		}
	}
	required := []string{"EXCHANGE_MAIL_DOMAIN"}
	if mode == "ansible" {
		required = append(required, "EXCHANGE_HOST", "EXCHANGE_SERVER_FQDN", "EXCHANGE_WINRM_USER", "EXCHANGE_WINRM_PASSWORD")
	}
	if environment == "production" {
		// Placement is not an authorization boundary. An empty OU lets Exchange
		// choose its default container; production still pins the database and DC.
		required = append(required, "EXCHANGE_MAILBOX_DATABASE", "EXCHANGE_DOMAIN_CONTROLLER", "EXCHANGE_STATE_DIRECTORY")
		if strings.Contains(os.Getenv("KRB5_CONFIG"), "krb5.test.conf") {
			return Config{}, fmt.Errorf("test Kerberos configuration is forbidden in production")
		}
	}
	for _, name := range required {
		value := strings.TrimSpace(os.Getenv(name))
		if value == "" || strings.Contains(value, "replace-with-") {
			return Config{}, fmt.Errorf("%s must be explicitly configured", name)
		}
	}
	token := os.Getenv("API_TOKEN")
	if token != "" && (len(token) < 32 || strings.TrimSpace(token) == "" || strings.Contains(token, "replace-with-")) {
		return Config{}, fmt.Errorf("API_TOKEN, when configured, must be a non-placeholder value of at least 32 bytes")
	}
	if mode == "ansible" {
		if err := validateLegacyConnection(environment); err != nil {
			return Config{}, err
		}
	}
	concurrency, err := envInt("EXCHANGE_MAX_CONCURRENT_OPERATIONS", 2, 1, 16)
	if err != nil {
		return Config{}, err
	}
	reset, err := envBool("EXCHANGE_RESET_PASSWORD_ON_NEXT_LOGON", false)
	if err != nil {
		return Config{}, err
	}
	bypass, err := envBool("EXCHANGE_BYPASS_GROUP_MANAGER_CHECK", true)
	if err != nil {
		return Config{}, err
	}
	timeout, err := envDuration("EXCHANGE_OPERATION_TIMEOUT", 5*time.Minute)
	if err != nil {
		return Config{}, err
	}
	localTemp := envOrDefault("ANSIBLE_LOCAL_TEMP", filepath.Join(os.TempDir(), "exchange-automation-ansible"))
	return Config{
		ConnectionMode: mode, DirectConnection: connection,
		PythonBinary: envOrDefault("EXCHANGE_PYTHON_BINARY", "python3"),
		DirectWorker: envOrDefault("EXCHANGE_DIRECT_WORKER", "automation/direct/exchange_psrp.py"),
		HTTPAddress:  envOrDefault("HTTP_ADDRESS", "127.0.0.1:8080"), APIToken: token,
		StateDirectory:           envOrDefault("EXCHANGE_STATE_DIRECTORY", filepath.Join(os.TempDir(), "exchange-automation-state")),
		MailDomain:               strings.TrimSpace(os.Getenv("EXCHANGE_MAIL_DOMAIN")),
		UPNSuffix:                strings.TrimSpace(os.Getenv("EXCHANGE_UPN_SUFFIX")),
		OrganizationalUnit:       strings.TrimSpace(os.Getenv("EXCHANGE_ORGANIZATIONAL_UNIT")),
		MailboxDatabase:          strings.TrimSpace(os.Getenv("EXCHANGE_MAILBOX_DATABASE")),
		DomainController:         strings.TrimSpace(os.Getenv("EXCHANGE_DOMAIN_CONTROLLER")),
		ResetPasswordOnNextLogon: reset, BypassGroupManagerCheck: bypass, MaxConcurrentOperations: concurrency,
		AnsiblePlaybookBinary: envOrDefault("ANSIBLE_PLAYBOOK_BINARY", "ansible-playbook"),
		AnsibleInventory:      envOrDefault("ANSIBLE_INVENTORY", "automation/inventory/hosts.yml"),
		AnsiblePlaybook:       envOrDefault("ANSIBLE_PLAYBOOK", "automation/playbooks/exchange_operation.yml"),
		AnsibleLocalTemp:      localTemp, ExchangeOperationTimeout: timeout,
	}, nil
}

// Kept only for explicit rollback; direct mode never uses these settings.
func validateLegacyConnection(environment string) error {
	scheme := envOrDefault("EXCHANGE_WINRM_SCHEME", "http")
	if scheme != "http" && scheme != "https" {
		return fmt.Errorf("EXCHANGE_WINRM_SCHEME must be http or https")
	}
	if envOrDefault("EXCHANGE_PSRP_AUTH", "kerberos") != "kerberos" {
		return fmt.Errorf("this two-hop Exchange workflow requires EXCHANGE_PSRP_AUTH=kerberos")
	}
	certificate := envOrDefault("EXCHANGE_WINRM_CERT_VALIDATION", "validate")
	if certificate != "validate" && certificate != "ignore" {
		return fmt.Errorf("invalid certificate validation policy")
	}
	if environment == "production" && certificate != "validate" {
		return fmt.Errorf("production requires certificate validation")
	}
	defaultPort := 5985
	if scheme == "https" {
		defaultPort = 5986
	}
	if _, err := envInt("EXCHANGE_WINRM_PORT", defaultPort, 1, 65535); err != nil {
		return err
	}
	operationSeconds, err := envInt("EXCHANGE_WINRM_OPERATION_TIMEOUT", 60, 1, 3600)
	if err != nil {
		return err
	}
	readSeconds, err := envInt("EXCHANGE_WINRM_READ_TIMEOUT", 70, 1, 7200)
	if err != nil {
		return err
	}
	if readSeconds <= operationSeconds {
		return fmt.Errorf("WinRM read timeout must exceed operation timeout")
	}
	return nil
}
func envOrDefault(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}
func envBool(name string, fallback bool) (bool, error) {
	value := os.Getenv(name)
	if value == "" {
		return fallback, nil
	}
	parsed, err := strconv.ParseBool(value)
	if err != nil {
		return false, fmt.Errorf("%s must be a boolean", name)
	}
	return parsed, nil
}
func envInt(name string, fallback, min, max int) (int, error) {
	value := os.Getenv(name)
	if value == "" {
		return fallback, nil
	}
	parsed, err := strconv.Atoi(value)
	if err != nil || parsed < min || parsed > max {
		return 0, fmt.Errorf("%s must be between %d and %d", name, min, max)
	}
	return parsed, nil
}
func envDuration(name string, fallback time.Duration) (time.Duration, error) {
	value := os.Getenv(name)
	if value == "" {
		return fallback, nil
	}
	parsed, err := time.ParseDuration(value)
	if err != nil || parsed <= 0 {
		return 0, fmt.Errorf("%s must be a positive duration", name)
	}
	return parsed, nil
}
