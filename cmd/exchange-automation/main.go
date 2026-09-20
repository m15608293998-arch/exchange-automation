package main

import (
	"context"
	"errors"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/m15608293998-arch/exchange-automation/internal/ansible"
	"github.com/m15608293998-arch/exchange-automation/internal/api"
	"github.com/m15608293998-arch/exchange-automation/internal/automation"
	"github.com/m15608293998-arch/exchange-automation/internal/config"
	"github.com/m15608293998-arch/exchange-automation/internal/direct"
	"github.com/m15608293998-arch/exchange-automation/internal/exchange"
)

func main() {
	logger := log.New(os.Stdout, "exchange-automation ", log.Ldate|log.Ltime|log.LUTC)

	settings, err := config.Load()
	if err != nil {
		logger.Fatalf("configuration error: %v", err)
	}
	instanceLock, err := lockInstance(settings.StateDirectory)
	if err != nil {
		logger.Fatalf("instance lock error: %v", err)
	}
	defer instanceLock.Close()

	var runner automation.Executor
	if settings.ConnectionMode == "direct" {
		runner, err = direct.NewRunner(settings.PythonBinary, settings.DirectWorker, settings.DirectConnection)
	} else {
		runner, err = ansible.NewRunner(settings.AnsiblePlaybookBinary, settings.AnsibleInventory, settings.AnsiblePlaybook, settings.AnsibleLocalTemp)
	}
	if err != nil {
		logger.Fatalf("Exchange runner configuration error: %v", err)
	}

	exchangeService, err := exchange.NewService(runner, exchange.Config{
		MailDomain:               settings.MailDomain,
		UPNSuffix:                settings.UPNSuffix,
		DomainController:         settings.DomainController,
		StateDirectory:           settings.StateDirectory,
		MaxConcurrentOperations:  settings.MaxConcurrentOperations,
		OrganizationalUnit:       settings.OrganizationalUnit,
		MailboxDatabase:          settings.MailboxDatabase,
		ResetPasswordOnNextLogon: settings.ResetPasswordOnNextLogon,
		BypassGroupManagerCheck:  settings.BypassGroupManagerCheck,
	})
	if err != nil {
		logger.Fatalf("Exchange service configuration error: %v", err)
	}

	handler, err := api.NewHandler(exchangeService, logger, settings.ExchangeOperationTimeout, settings.APIToken)
	if err != nil {
		logger.Fatalf("HTTP handler configuration error: %v", err)
	}

	baseContext, cancelRequests := context.WithCancel(context.Background())
	defer cancelRequests()
	server := &http.Server{
		Addr:              settings.HTTPAddress,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      settings.ExchangeOperationTimeout + 10*time.Second,
		IdleTimeout:       60 * time.Second,
		BaseContext:       func(net.Listener) context.Context { return baseContext },
	}

	shutdownSignals, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	shutdownDone := make(chan struct{})
	go func() {
		defer close(shutdownDone)
		<-shutdownSignals.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), settings.ExchangeOperationTimeout+15*time.Second)
		defer cancel()
		if err := server.Shutdown(shutdownCtx); err != nil {
			logger.Printf("HTTP shutdown error: %v", err)
			cancelRequests()
			_ = server.Close()
			// Allow canceled worker processes to release their local resources.
			cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cleanupCancel()
			_ = server.Shutdown(cleanupCtx)
		}
	}()

	logger.Printf("listening address=%s connection_mode=%s", settings.HTTPAddress, settings.ConnectionMode)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		logger.Fatalf("HTTP server error: %v", err)
	}
	<-shutdownDone
}

func lockInstance(directory string) (*os.File, error) {
	if err := os.MkdirAll(directory, 0700); err != nil {
		return nil, err
	}
	info, err := os.Lstat(directory)
	if err != nil {
		return nil, err
	}
	if !info.IsDir() || info.Mode().Perm()&0077 != 0 {
		return nil, errors.New("state directory must be private (0700)")
	}
	file, err := os.OpenFile(filepath.Join(directory, "service.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		file.Close()
		return nil, errors.New("another service instance holds the state directory lock")
	}
	return file, nil
}
