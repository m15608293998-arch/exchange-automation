package api

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/m15608293998-arch/exchange-automation/internal/exchange"
)

func TestAuthenticationProtectsOperationsButAllowsHealth(t *testing.T) {
	service := &fakeService{}
	handler, err := NewHandler(service, log.New(io.Discard, "", 0), time.Second, testToken)
	if err != nil {
		t.Fatal(err)
	}
	for _, authorization := range []string{"", "Bearer wrong", testToken} {
		request := httptest.NewRequest("POST", "/api/exchange/users", strings.NewReader(`{}`))
		request.Header.Set("Authorization", authorization)
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		if response.Code != 401 || response.Header().Get("X-Request-ID") == "" {
			t.Fatal("unauthenticated operation was not rejected with request ID")
		}
	}
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest("GET", "/healthz", nil))
	if response.Code != 200 {
		t.Fatal("health requires authentication")
	}
}

func TestNoTokenAllowsBothOperationsWithoutAuthorization(t *testing.T) {
	service := &fakeService{}
	handler, err := NewHandler(service, log.New(io.Discard, "", 0), time.Second, "")
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest("POST", "/api/exchange/users", strings.NewReader(`{"login_name":"alice","display_name":"Alice"}`))
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != 200 || service.onboardInput.LoginName != "alice" {
		t.Fatalf("unauthenticated onboard failed: %d %s", response.Code, response.Body.String())
	}
	response = httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest("POST", "/api/exchange/users/alice/offboard", nil))
	if response.Code != 200 || service.offboardLogin != "alice" {
		t.Fatalf("unauthenticated offboard failed: %d %s", response.Code, response.Body.String())
	}
}

func TestUncertainTimeoutIncludesConfirmedPartialProgress(t *testing.T) {
	service := &fakeService{
		onboardResult: exchange.OnboardResult{LoginName: "alice", MailboxID: "confirmed-guid", AddedGroups: []string{"done"}},
		onboardErr:    &exchange.OperationError{Code: exchange.CodeAutomationFailure, Step: "ensure_group_member", Target: "failed-group", StateUnknown: true, Cause: context.DeadlineExceeded},
	}
	response := httptest.NewRecorder()
	newTestHandler(t, service).ServeHTTP(response, httptest.NewRequest("POST", "/api/exchange/users", strings.NewReader(`{"login_name":"alice"}`)))
	var body errorResponse
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if response.Code != 504 || !body.Error.StateUnknown || body.Error.Target != "failed-group" || body.PartialResult == nil || body.RequestID == "" {
		t.Fatalf("lost outcome information: %s", response.Body.String())
	}
}

func TestCredentialsStayOutOfResponsesAndAudit(t *testing.T) {
	var logs bytes.Buffer
	handler, _ := NewHandler(&fakeService{onboardResult: exchange.OnboardResult{LoginName: "alice"}}, log.New(&logs, "", 0), time.Second, testToken)
	request := httptest.NewRequest("POST", "/api/exchange/users", strings.NewReader(`{"login_name":"alice","display_name":"Alice","initial_password":"do-not-log-this-secret"}`))
	request.Header.Set("Authorization", "Bearer "+testToken)
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	for _, secret := range []string{"do-not-log-this-secret", testToken} {
		if strings.Contains(logs.String(), secret) || strings.Contains(response.Body.String(), secret) {
			t.Fatal("credential disclosed")
		}
	}
	if !strings.Contains(logs.String(), "request_id=") || !strings.Contains(logs.String(), "exchange_operation") {
		t.Fatal("missing audit event")
	}
}

func TestOffboardRejectsIgnoredScopeBody(t *testing.T) {
	response := httptest.NewRecorder()
	newTestHandler(t, &fakeService{}).ServeHTTP(response, httptest.NewRequest("POST", "/api/exchange/users/alice/offboard", strings.NewReader(`{"groups":[]}`)))
	if response.Code != http.StatusBadRequest {
		t.Fatal("offboard accepted an ignored body")
	}
}
