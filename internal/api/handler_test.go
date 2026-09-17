package api

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/m15608293998-arch/exchange-automation/internal/exchange"
)

type fakeService struct {
	onboardInput   exchange.OnboardInput
	onboardResult  exchange.OnboardResult
	onboardErr     error
	offboardLogin  string
	offboardResult exchange.OffboardResult
	offboardErr    error
}

func (f *fakeService) Onboard(_ context.Context, input exchange.OnboardInput) (exchange.OnboardResult, error) {
	f.onboardInput = input
	return f.onboardResult, f.onboardErr
}

func (f *fakeService) Offboard(_ context.Context, loginName string) (exchange.OffboardResult, error) {
	f.offboardLogin = loginName
	return f.offboardResult, f.offboardErr
}

func TestOnboardEndpoint(t *testing.T) {
	t.Parallel()

	service := &fakeService{onboardResult: exchange.OnboardResult{
		LoginName: "slpeng", DisplayName: "江流", PrimarySMTPAddress: "slpeng@bjwgby.com", Created: true,
		AddedGroups: []string{"all@bjwgby.com"}, ExistingGroups: []string{},
	}}
	handler := newTestHandler(t, service)
	body := []byte(`{"login_name":"slpeng","display_name":"江流","initial_password":"secret-value","groups":["all"]}`)
	request := httptest.NewRequest(http.MethodPost, "/api/exchange/users", bytes.NewReader(body))
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusCreated {
		t.Fatalf("status = %d, want %d; body=%s", response.Code, http.StatusCreated, response.Body.String())
	}
	if service.onboardInput.InitialPassword != "secret-value" {
		t.Fatal("initial_password was not decoded")
	}
	if bytes.Contains(response.Body.Bytes(), []byte("secret-value")) {
		t.Fatal("response contains initial_password")
	}
}

func TestOnboardEndpointRejectsUnknownField(t *testing.T) {
	t.Parallel()

	handler := newTestHandler(t, &fakeService{})
	request := httptest.NewRequest(http.MethodPost, "/api/exchange/users", bytes.NewBufferString(`{"unknown":true}`))
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusBadRequest)
	}
}

func TestOffboardEndpointMapsNotFound(t *testing.T) {
	t.Parallel()

	service := &fakeService{offboardErr: &exchange.OperationError{
		Code: exchange.CodeUserNotFound, Message: "Mailbox was not found",
	}}
	handler := newTestHandler(t, service)
	request := httptest.NewRequest(http.MethodPost, "/api/exchange/users/missing/offboard", nil)
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want %d; body=%s", response.Code, http.StatusNotFound, response.Body.String())
	}
	var payload errorResponse
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if payload.Error.Code != exchange.CodeUserNotFound {
		t.Fatalf("error code = %q", payload.Error.Code)
	}
}

func TestHealthEndpoint(t *testing.T) {
	t.Parallel()

	handler := newTestHandler(t, &fakeService{})
	request := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusOK)
	}
}

func newTestHandler(t *testing.T, service exchangeService) http.Handler {
	t.Helper()
	handler, err := NewHandler(service, log.New(io.Discard, "", 0), time.Second)
	if err != nil {
		t.Fatalf("NewHandler() error = %v", err)
	}
	return handler
}
