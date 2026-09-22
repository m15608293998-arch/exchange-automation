package config

import "testing"

func testEnvironment(t *testing.T) {
	t.Helper()
	for key, value := range map[string]string{
		"EXCHANGE_CONNECTION_MODE": "ansible",
		"APP_ENV":                  "test", "EXCHANGE_MAIL_DOMAIN": "example.com", "EXCHANGE_HOST": "192.0.2.1", "EXCHANGE_SERVER_FQDN": "exchange.example.com",
		"EXCHANGE_WINRM_USER": "svc@EXAMPLE.COM", "EXCHANGE_WINRM_PASSWORD": "test-only", "API_TOKEN": "test-token-at-least-thirty-two-bytes",
		"KRB5_CONFIG": "", "EXCHANGE_WINRM_SCHEME": "http", "EXCHANGE_PSRP_AUTH": "kerberos", "EXCHANGE_WINRM_CERT_VALIDATION": "validate",
		"EXCHANGE_WINRM_OPERATION_TIMEOUT": "60", "EXCHANGE_WINRM_READ_TIMEOUT": "70", "EXCHANGE_MAX_CONCURRENT_OPERATIONS": "2",
		"EXCHANGE_ORGANIZATIONAL_UNIT": "", "EXCHANGE_MAILBOX_DATABASE": "", "EXCHANGE_DOMAIN_CONTROLLER": "", "EXCHANGE_STATE_DIRECTORY": "",
	} {
		t.Setenv(key, value)
	}
}

func TestDirectIsDefaultWithoutWindowsShellSettings(t *testing.T) {
	testEnvironment(t)
	t.Setenv("EXCHANGE_CONNECTION_MODE", "")
	t.Setenv("EXCHANGE_POWERSHELL_URL", "http://exchange.example.com/PowerShell/")
	t.Setenv("EXCHANGE_AUTH", "kerberos")
	t.Setenv("EXCHANGE_CREDENTIAL_FILE", "/run/secrets/exchange.json")
	t.Setenv("EXCHANGE_USERNAME", "")
	t.Setenv("EXCHANGE_PASSWORD", "")
	for _, name := range []string{"EXCHANGE_HOST", "EXCHANGE_SERVER_FQDN", "EXCHANGE_WINRM_USER", "EXCHANGE_WINRM_PASSWORD"} {
		t.Setenv(name, "")
	}
	// Obsolete Windows settings cannot change the new transport's security policy.
	t.Setenv("EXCHANGE_PSRP_AUTH", "basic")
	t.Setenv("EXCHANGE_WINRM_CERT_VALIDATION", "ignore")
	cfg, err := Load()
	if err != nil || cfg.ConnectionMode != "direct" {
		t.Fatalf("default direct mode: %#v %v", cfg.ConnectionMode, err)
	}
	t.Setenv("EXCHANGE_POWERSHELL_URL", "")
	if _, err := Load(); err == nil {
		t.Fatal("must not silently fall back to legacy settings")
	}
}
func TestProductionRequiresDatabaseDCAndDurableStateButNotOU(t *testing.T) {
	testEnvironment(t)
	t.Setenv("APP_ENV", "production")
	if _, err := Load(); err == nil {
		t.Fatal("production accepted missing placement")
	}
	for key, value := range map[string]string{"EXCHANGE_MAILBOX_DATABASE": "DB01", "EXCHANGE_DOMAIN_CONTROLLER": "dc.example.com", "EXCHANGE_STATE_DIRECTORY": "/var/lib/exchange-automation"} {
		t.Setenv(key, value)
	}
	if _, err := Load(); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"EXCHANGE_MAILBOX_DATABASE", "EXCHANGE_DOMAIN_CONTROLLER", "EXCHANGE_STATE_DIRECTORY"} {
		t.Run(name, func(t *testing.T) {
			t.Setenv(name, "")
			if _, err := Load(); err == nil {
				t.Fatalf("production accepted missing %s", name)
			}
		})
	}
	t.Setenv("EXCHANGE_WINRM_CERT_VALIDATION", "ignore")
	if _, err := Load(); err == nil {
		t.Fatal("production accepted ignored certificate validation")
	}
}
func TestConnectionConfigurationFailsClosed(t *testing.T) {
	for _, key := range []string{"EXCHANGE_HOST", "EXCHANGE_SERVER_FQDN", "EXCHANGE_WINRM_USER", "EXCHANGE_WINRM_PASSWORD"} {
		t.Run(key, func(t *testing.T) {
			testEnvironment(t)
			t.Setenv(key, "")
			if _, err := Load(); err == nil {
				t.Fatal("missing configuration accepted")
			}
		})
	}
	t.Run("timeouts", func(t *testing.T) {
		testEnvironment(t)
		t.Setenv("EXCHANGE_WINRM_READ_TIMEOUT", "60")
		if _, err := Load(); err == nil {
			t.Fatal("invalid timeout ordering")
		}
	})
	t.Run("authentication", func(t *testing.T) {
		testEnvironment(t)
		t.Setenv("EXCHANGE_PSRP_AUTH", "basic")
		if _, err := Load(); err == nil {
			t.Fatal("unsupported auth accepted")
		}
	})
}

func TestAPITokenIsOptionalButInvalidConfiguredTokenFails(t *testing.T) {
	testEnvironment(t)
	t.Setenv("API_TOKEN", "")
	if cfg, err := Load(); err != nil || cfg.APIToken != "" {
		t.Fatalf("empty token should allow unauthenticated API: %v", err)
	}
	for _, token := range []string{"short", "                                ", "replace-with-at-least-32-random-bytes"} {
		t.Setenv("API_TOKEN", token)
		if _, err := Load(); err == nil {
			t.Fatal("invalid configured token accepted")
		}
	}
}
