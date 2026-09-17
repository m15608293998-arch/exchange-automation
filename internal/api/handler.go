package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"time"

	"github.com/m15608293998-arch/exchange-automation/internal/exchange"
)

const maxRequestBodyBytes = 64 << 10

type exchangeService interface {
	Onboard(ctx context.Context, input exchange.OnboardInput) (exchange.OnboardResult, error)
	Offboard(ctx context.Context, loginName string) (exchange.OffboardResult, error)
}

type Handler struct {
	service exchangeService
	logger  *log.Logger
	timeout time.Duration
}

type errorResponse struct {
	Error         errorDetail `json:"error"`
	PartialResult any         `json:"partial_result,omitempty"`
}

type errorDetail struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func NewHandler(service exchangeService, logger *log.Logger, timeout time.Duration) (http.Handler, error) {
	if service == nil {
		return nil, fmt.Errorf("Exchange service must not be nil")
	}
	if logger == nil {
		return nil, fmt.Errorf("logger must not be nil")
	}
	if timeout <= 0 {
		return nil, fmt.Errorf("operation timeout must be greater than zero")
	}

	handler := &Handler{service: service, logger: logger, timeout: timeout}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", handler.health)
	mux.HandleFunc("POST /api/exchange/users", handler.onboard)
	mux.HandleFunc("POST /api/exchange/users/{login_name}/offboard", handler.offboard)
	return handler.logRequests(mux), nil
}

func (h *Handler) health(response http.ResponseWriter, _ *http.Request) {
	writeJSON(response, http.StatusOK, map[string]string{"status": "ok"})
}

func (h *Handler) onboard(response http.ResponseWriter, request *http.Request) {
	var input exchange.OnboardInput
	if err := decodeJSON(response, request, &input); err != nil {
		writeError(response, http.StatusBadRequest, exchange.CodeInvalidRequest, err.Error(), nil)
		return
	}

	ctx, cancel := context.WithTimeout(request.Context(), h.timeout)
	defer cancel()

	result, err := h.service.Onboard(ctx, input)
	if err != nil {
		status, detail := statusForError(err)
		var partial any
		if result.LoginName != "" {
			partial = result
		}
		h.logger.Printf("onboard failed login_name=%q code=%s", input.LoginName, detail.Code)
		writeError(response, status, detail.Code, detail.Message, partial)
		return
	}

	status := http.StatusOK
	if result.Created {
		status = http.StatusCreated
	}
	writeJSON(response, status, result)
}

func (h *Handler) offboard(response http.ResponseWriter, request *http.Request) {
	loginName := request.PathValue("login_name")
	ctx, cancel := context.WithTimeout(request.Context(), h.timeout)
	defer cancel()

	result, err := h.service.Offboard(ctx, loginName)
	if err != nil {
		status, detail := statusForError(err)
		var partial any
		if result.LoginName != "" && len(result.RemovedGroups) > 0 {
			partial = result
		}
		h.logger.Printf("offboard failed login_name=%q code=%s", loginName, detail.Code)
		writeError(response, status, detail.Code, detail.Message, partial)
		return
	}

	writeJSON(response, http.StatusOK, result)
}

func decodeJSON(response http.ResponseWriter, request *http.Request, destination any) error {
	request.Body = http.MaxBytesReader(response, request.Body, maxRequestBodyBytes)
	decoder := json.NewDecoder(request.Body)
	decoder.DisallowUnknownFields()

	if err := decoder.Decode(destination); err != nil {
		return fmt.Errorf("request body must be a valid JSON object: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		if err == nil {
			return fmt.Errorf("request body must contain exactly one JSON object")
		}
		return fmt.Errorf("request body must contain exactly one JSON object: %w", err)
	}
	return nil
}

func statusForError(err error) (int, errorDetail) {
	if errors.Is(err, context.DeadlineExceeded) {
		return http.StatusGatewayTimeout, errorDetail{Code: exchange.CodeAutomationFailure, Message: "Exchange operation timed out"}
	}

	var operationErr *exchange.OperationError
	if !errors.As(err, &operationErr) {
		return http.StatusInternalServerError, errorDetail{Code: "INTERNAL_ERROR", Message: "Internal server error"}
	}

	status := http.StatusBadGateway
	switch operationErr.Code {
	case exchange.CodeInvalidRequest:
		status = http.StatusBadRequest
	case exchange.CodeUserNotFound:
		status = http.StatusNotFound
	case exchange.CodeRecipientConflict:
		status = http.StatusConflict
	case exchange.CodeGroupNotFound:
		status = http.StatusUnprocessableEntity
	case exchange.CodeAutomationFailure, exchange.CodeExchangeFailure:
		status = http.StatusBadGateway
	}
	return status, errorDetail{Code: operationErr.Code, Message: operationErr.Message}
}

func writeError(response http.ResponseWriter, status int, code, message string, partial any) {
	writeJSON(response, status, errorResponse{
		Error:         errorDetail{Code: code, Message: message},
		PartialResult: partial,
	})
}

func writeJSON(response http.ResponseWriter, status int, value any) {
	response.Header().Set("Content-Type", "application/json; charset=utf-8")
	response.WriteHeader(status)
	_ = json.NewEncoder(response).Encode(value)
}

func (h *Handler) logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		started := time.Now()
		tracked := &statusWriter{ResponseWriter: response, status: http.StatusOK}
		next.ServeHTTP(tracked, request)
		h.logger.Printf("http_request method=%s path=%q status=%d duration=%s", request.Method, request.URL.Path, tracked.status, time.Since(started).Round(time.Millisecond))
	})
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(status int) {
	w.status = status
	w.ResponseWriter.WriteHeader(status)
}
