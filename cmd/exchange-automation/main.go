package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/m15608293998-arch/exchange-automation/internal/ansible"
	"github.com/m15608293998-arch/exchange-automation/internal/api"
	"github.com/m15608293998-arch/exchange-automation/internal/config"
	"github.com/m15608293998-arch/exchange-automation/internal/exchange"
)

func main() {
	logger := log.New(os.Stdout, "exchange-automation ", log.Ldate|log.Ltime|log.LUTC)

	settings, err := config.Load()
	if err != nil {
		logger.Fatalf("configuration error: %v", err)
	}

	runner, err := ansible.NewRunner(
		settings.AnsiblePlaybookBinary,
		settings.AnsibleInventory,
		settings.AnsiblePlaybook,
		settings.AnsibleLocalTemp,
	)
	if err != nil {
		logger.Fatalf("Ansible runner configuration error: %v", err)
	}

	exchangeService, err := exchange.NewService(runner, exchange.Config{
		MailDomain:               settings.MailDomain,
		OrganizationalUnit:       settings.OrganizationalUnit,
		MailboxDatabase:          settings.MailboxDatabase,
		ResetPasswordOnNextLogon: settings.ResetPasswordOnNextLogon,
		BypassGroupManagerCheck:  settings.BypassGroupManagerCheck,
	})
	if err != nil {
		logger.Fatalf("Exchange service configuration error: %v", err)
	}

	handler, err := api.NewHandler(exchangeService, logger, settings.ExchangeOperationTimeout)
	if err != nil {
		logger.Fatalf("HTTP handler configuration error: %v", err)
	}

	server := &http.Server{
		Addr:              settings.HTTPAddress,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      settings.ExchangeOperationTimeout + 10*time.Second,
		IdleTimeout:       60 * time.Second,
	}

	shutdownSignals, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		<-shutdownSignals.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := server.Shutdown(shutdownCtx); err != nil {
			logger.Printf("HTTP shutdown error: %v", err)
		}
	}()

	logger.Printf("listening address=%s", settings.HTTPAddress)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		logger.Fatalf("HTTP server error: %v", err)
	}
}
