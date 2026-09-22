package api

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"mime"
	"net/http"
	"strings"
	"time"

	"github.com/m15608293998-arch/exchange-automation/internal/exchange"
)

const maxRequestBodyBytes = 64 << 10

type exchangeService interface {
	Onboard(ctx context.Context, input exchange.OnboardInput) (exchange.OnboardResult, error)
	Offboard(ctx context.Context, loginName string) (exchange.OffboardResult, error)
}

type Handler struct {
	service     exchangeService
	logger      *log.Logger
	timeout     time.Duration
	tokenHash   [32]byte
	requireAuth bool
}

type errorResponse struct {
	Error         errorDetail `json:"error"`
	PartialResult any         `json:"partial_result,omitempty"`
	RequestID     string      `json:"request_id"`
}

type errorDetail struct {
	Code         string `json:"code"`
	Message      string `json:"message"`
	Step         string `json:"step,omitempty"`
	Target       string `json:"target,omitempty"`
	StateUnknown bool   `json:"state_unknown"`
}

func NewHandler(service exchangeService, logger *log.Logger, timeout time.Duration, token string) (http.Handler, error) {
	if service == nil {
		return nil, fmt.Errorf("Exchange service must not be nil")
	}
	if logger == nil {
		return nil, fmt.Errorf("logger must not be nil")
	}
	if timeout <= 0 {
		return nil, fmt.Errorf("operation timeout must be greater than zero")
	}

	if token != "" && (len(token) < 32 || strings.TrimSpace(token) == "") {
		return nil, fmt.Errorf("API token must contain at least 32 bytes")
	}
	handler := &Handler{service: service, logger: logger, timeout: timeout, tokenHash: sha256.Sum256([]byte(token)), requireAuth: token != ""}
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
	contentType, _, err := mime.ParseMediaType(request.Header.Get("Content-Type"))
	if err != nil || contentType != "application/json" {
		writeError(response, http.StatusUnsupportedMediaType, exchange.CodeInvalidRequest, "Content-Type must be application/json", nil)
		return
	}
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
		if result.MailboxID != "" {
			partial = result
		}
		h.audit(response, "onboard", result, err)
		writeOperationError(response, status, detail, partial)
		return
	}

	status := http.StatusOK
	if result.Created {
		status = http.StatusCreated
	}
	h.audit(response, "onboard", result, nil)
	writeJSON(response, status, result)
}

func (h *Handler) offboard(response http.ResponseWriter, request *http.Request) {
	if request.Body != nil {
		body, err := io.ReadAll(http.MaxBytesReader(response, request.Body, 1))
		if err != nil || len(body) != 0 {
			writeError(response, http.StatusBadRequest, exchange.CodeInvalidRequest, "offboard does not accept a request body", nil)
			return
		}
	}
	loginName := request.PathValue("login_name")
	ctx, cancel := context.WithTimeout(request.Context(), h.timeout)
	defer cancel()

	result, err := h.service.Offboard(ctx, loginName)
	if err != nil {
		status, detail := statusForError(err)
		var partial any
		if result.MailboxID != "" {
			partial = result
		}
		h.audit(response, "offboard", result, err)
		writeOperationError(response, status, detail, partial)
		return
	}

	h.audit(response, "offboard", result, nil)
	writeJSON(response, http.StatusOK, result)
}

func decodeJSON(response http.ResponseWriter, request *http.Request, destination any) error {
	request.Body = http.MaxBytesReader(response, request.Body, maxRequestBodyBytes)
	decoder := json.NewDecoder(request.Body)
	decoder.DisallowUnknownFields()

	if err := decoder.Decode(destination); err != nil {
		return fmt.Errorf("request body must be a valid JSON object with supported fields and at most 64 KiB")
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		if err == nil {
			return fmt.Errorf("request body must contain exactly one JSON object")
		}
		return fmt.Errorf("request body must contain exactly one JSON object")
	}
	return nil
}

func statusForError(err error) (int, errorDetail) {
	var operationErr *exchange.OperationError
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
		detail := errorDetail{Code: exchange.CodeAutomationFailure, Message: "Exchange operation interrupted; reconcile the outcome before retrying"}
		if errors.As(err, &operationErr) {
			detail.Step, detail.Target, detail.StateUnknown = operationErr.Step, operationErr.Target, operationErr.StateUnknown
		}
		return http.StatusGatewayTimeout, detail
	}
	if !errors.As(err, &operationErr) {
		return http.StatusInternalServerError, errorDetail{Code: "INTERNAL_ERROR", Message: "Internal server error"}
	}

	status := http.StatusBadGateway
	switch operationErr.Code {
	case exchange.CodeInvalidRequest:
		status = http.StatusBadRequest
	case exchange.CodeUserNotFound:
		status = http.StatusNotFound
	case exchange.CodeRecipientConflict, exchange.CodeOperationBusy, exchange.CodeStateUnknown:
		status = http.StatusConflict
	case exchange.CodeGroupNotFound, exchange.CodeGroupType:
		status = http.StatusUnprocessableEntity
	case exchange.CodeCapacity:
		status = http.StatusTooManyRequests
	case exchange.CodeAutomationFailure, exchange.CodeExchangeFailure:
		status = http.StatusBadGateway
	}
	return status, errorDetail{Code: operationErr.Code, Message: operationErr.Message, Step: operationErr.Step, Target: operationErr.Target, StateUnknown: operationErr.StateUnknown}
}

func writeError(response http.ResponseWriter, status int, code, message string, partial any) {
	writeOperationError(response, status, errorDetail{Code: code, Message: message}, partial)
}

func writeOperationError(response http.ResponseWriter, status int, detail errorDetail, partial any) {
	writeJSON(response, status, errorResponse{
		Error:         detail,
		PartialResult: partial,
		RequestID:     response.Header().Get("X-Request-ID"),
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
		var requestID [16]byte
		if _, err := rand.Read(requestID[:]); err != nil {
			http.Error(response, "request ID unavailable", 500)
			return
		}
		response.Header().Set("X-Request-ID", hex.EncodeToString(requestID[:]))
		tracked := &statusWriter{ResponseWriter: response, status: http.StatusOK}
		defer func() {
			h.logger.Printf("http_request request_id=%s method=%s path=%q status=%d duration=%s", response.Header().Get("X-Request-ID"), request.Method, request.URL.Path, tracked.status, time.Since(started).Round(time.Millisecond))
		}()
		if h.requireAuth && request.URL.Path != "/healthz" {
			authorization := request.Header.Get("Authorization")
			token := strings.TrimPrefix(authorization, "Bearer ")
			hash := sha256.Sum256([]byte(token))
			if !strings.HasPrefix(authorization, "Bearer ") || subtle.ConstantTimeCompare(hash[:], h.tokenHash[:]) != 1 {
				writeError(tracked, http.StatusUnauthorized, "UNAUTHORIZED", "Valid service bearer token required", nil)
				return
			}
		}
		next.ServeHTTP(tracked, request)
	})
}

func (h *Handler) audit(response http.ResponseWriter, action string, result any, err error) {
	data, _ := json.Marshal(result) // Result types never contain credentials.
	detail := errorDetail{}
	diagnostic := ""
	if err != nil {
		_, detail = statusForError(err)
		diagnostic = err.Error()
	}
	h.logger.Printf("exchange_operation request_id=%s action=%s code=%q step=%q target=%q state_unknown=%t diagnostic=%q result=%s",
		response.Header().Get("X-Request-ID"), action, detail.Code, detail.Step, detail.Target, detail.StateUnknown, diagnostic, data)
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(status int) {
	w.status = status
	w.ResponseWriter.WriteHeader(status)
}
