package exchange

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/m15608293998-arch/exchange-automation/internal/automation"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"unicode"
	"unicode/utf8"
)

const maxGroupsPerRequest = 100

var (
	loginNameRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,19}$`)
	domainRE    = regexp.MustCompile(`^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:[.][a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$`)
	guidRE      = regexp.MustCompile(`(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
	errorTypeRE = regexp.MustCompile(`^[A-Za-z0-9_.]+$`)
)

type Config struct {
	MailDomain               string
	UPNSuffix                string
	OrganizationalUnit       string
	MailboxDatabase          string
	DomainController         string
	ResetPasswordOnNextLogon bool
	BypassGroupManagerCheck  bool
	MaxConcurrentOperations  int
	StateDirectory           string
}
type Service struct {
	executor  automation.Executor
	config    Config
	mu        sync.Mutex
	active    map[string]bool
	uncertain map[string]bool
}
type OnboardInput struct {
	LoginName       string   `json:"login_name"`
	DisplayName     string   `json:"display_name"`
	InitialPassword string   `json:"initial_password,omitempty"`
	Groups          []string `json:"groups"`
}
type OnboardResult struct {
	LoginName          string   `json:"login_name"`
	MailboxID          string   `json:"mailbox_id"`
	DisplayName        string   `json:"display_name"`
	UserPrincipalName  string   `json:"user_principal_name"`
	PrimarySMTPAddress string   `json:"primary_smtp_address"`
	Created            bool     `json:"created"`
	PasswordApplied    bool     `json:"password_applied"`
	AddedGroups        []string `json:"added_groups"`
	ExistingGroups     []string `json:"existing_groups"`
}
type OffboardResult struct {
	LoginName     string   `json:"login_name"`
	MailboxID     string   `json:"mailbox_id"`
	RemovedGroups []string `json:"removed_groups"`
}
type ensureMailboxData struct {
	Created            *bool  `json:"created"`
	MailboxID          string `json:"mailbox_id"`
	LoginName          string `json:"login_name"`
	DisplayName        string `json:"display_name"`
	UserPrincipalName  string `json:"user_principal_name"`
	PrimarySMTPAddress string `json:"primary_smtp_address"`
}
type groupMemberData struct {
	Group    string `json:"group"`
	GroupID  string `json:"group_id"`
	MemberID string `json:"member_id"`
	Added    *bool  `json:"added"`
	Removed  *bool  `json:"removed"`
}
type discoveredGroup struct {
	Identity string `json:"identity"`
	Label    string `json:"label"`
}
type discoverGroupsData struct {
	MailboxID string            `json:"mailbox_id"`
	Groups    []discoveredGroup `json:"groups"`
}

func NewService(executor automation.Executor, config Config) (*Service, error) {
	if executor == nil {
		return nil, fmt.Errorf("automation executor must not be nil")
	}
	config.MailDomain = strings.ToLower(strings.TrimPrefix(strings.TrimSpace(config.MailDomain), "@"))
	if config.UPNSuffix == "" {
		config.UPNSuffix = config.MailDomain
	}
	config.UPNSuffix = strings.ToLower(strings.TrimSpace(config.UPNSuffix))
	if !domainRE.MatchString(config.MailDomain) || !domainRE.MatchString(config.UPNSuffix) {
		return nil, fmt.Errorf("invalid Exchange mail domain or UPN suffix")
	}
	if config.MaxConcurrentOperations == 0 {
		config.MaxConcurrentOperations = 2
	}
	if config.MaxConcurrentOperations < 1 {
		return nil, fmt.Errorf("max concurrency must be positive")
	}
	if config.StateDirectory != "" {
		if err := os.MkdirAll(config.StateDirectory, 0700); err != nil {
			return nil, err
		}
		info, err := os.Lstat(config.StateDirectory)
		if err != nil || !info.IsDir() || info.Mode().Perm()&0077 != 0 {
			return nil, fmt.Errorf("state directory must be private (0700)")
		}
	}
	return &Service{executor: executor, config: config, active: map[string]bool{}, uncertain: map[string]bool{}}, nil
}

// Reject competing writes instead of hiding them in a timeout-prone queue.
func (s *Service) acquire(login string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.uncertain[login] {
		return &OperationError{Code: CodeStateUnknown, Message: "Previous operation has an unknown outcome; reconcile Exchange before restarting this service", StateUnknown: true}
	}
	if s.active[login] {
		return newOperationError(CodeOperationBusy, "Another operation is running for this user", nil)
	}
	if len(s.active) >= s.config.MaxConcurrentOperations {
		return newOperationError(CodeCapacity, "Operation capacity reached; retry later", nil)
	}
	if s.config.StateDirectory != "" {
		marker, err := os.OpenFile(s.pendingPath(login), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
		if os.IsExist(err) {
			s.uncertain[login] = true
			return &OperationError{Code: CodeStateUnknown, Message: "An unfinished operation is recorded; reconcile Exchange and the pending record before retrying", StateUnknown: true}
		}
		if err != nil {
			return newOperationError(CodeAutomationFailure, "Cannot record operation state", err)
		}
		if err = marker.Close(); err == nil {
			err = s.syncState()
		}
		if err != nil {
			return newOperationError(CodeAutomationFailure, "Cannot persist operation state", err)
		}
	}
	s.active[login] = true
	return nil
}
func (s *Service) release(login string, err error) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.active, login)
	if operationStateUnknown(err) {
		s.uncertain[login] = true
		return err
	}
	if s.config.StateDirectory != "" {
		removeErr := os.Remove(s.pendingPath(login))
		if removeErr == nil {
			removeErr = s.syncState()
		}
		if removeErr != nil {
			s.uncertain[login] = true
			return &OperationError{Code: CodeStateUnknown, Message: "Cannot finalize the operation journal; reconcile before retrying", Cause: removeErr, StateUnknown: true}
		}
	}
	return err
}
func (s *Service) pendingPath(login string) string {
	return filepath.Join(s.config.StateDirectory, login+".pending")
}
func (s *Service) syncState() error {
	directory, err := os.Open(s.config.StateDirectory)
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}
func (s *Service) run(ctx context.Context, operation string, parameters map[string]any) (automation.Result, error) {
	parameters["DomainController"] = s.config.DomainController
	result, err := s.executor.Execute(ctx, operation, parameters)
	mutation := operation == "ensure_mailbox" || operation == "ensure_group_member" || operation == "remove_group_member"
	if err != nil {
		return result, &OperationError{Code: CodeAutomationFailure, Message: "Automation execution failed; reconcile any uncertain changes", Cause: err, Step: operation, StateUnknown: mutation}
	}
	if !result.OK {
		failure := newOperationError(result.Code, result.Message, nil)
		if result.ErrorType != "" && len(result.ErrorType) <= 128 && errorTypeRE.MatchString(result.ErrorType) {
			failure.Cause = fmt.Errorf("remote error type: %s", result.ErrorType)
		}
		failure.Step, failure.StateUnknown = operation, result.StateUnknown
		return result, failure
	}
	return result, nil
}
func invalidResult(operation string) error {
	return &OperationError{Code: CodeAutomationFailure, Message: "Exchange returned an invalid or mismatched result", Step: operation,
		StateUnknown: operation == "ensure_mailbox" || operation == "ensure_group_member" || operation == "remove_group_member"}
}
func validGroups(groups []discoveredGroup) bool {
	if groups == nil {
		return false
	}
	seen := map[string]bool{}
	for _, group := range groups {
		key := strings.ToLower(group.Identity)
		if !guidRE.MatchString(key) || group.Label == "" || seen[key] {
			return false
		}
		seen[key] = true
	}
	return true
}
func (s *Service) Onboard(ctx context.Context, input OnboardInput) (result OnboardResult, err error) {
	input, err = normalizeOnboardInput(input)
	if err != nil {
		return result, err
	}
	if err = s.acquire(input.LoginName); err != nil {
		return result, err
	}
	defer func() { err = s.release(input.LoginName, err) }()
	// Resolve every group before New-Mailbox can create an account.
	groups := []discoveredGroup{}
	if len(input.Groups) > 0 {
		resolved, resolveErr := s.run(ctx, "resolve_groups", map[string]any{"GroupIdentities": input.Groups})
		if resolveErr != nil {
			return result, resolveErr
		}
		var data discoverGroupsData
		if decodeData(resolved.Data, &data) != nil || !validGroups(data.Groups) || len(data.Groups) == 0 {
			return result, invalidResult("resolve_groups")
		}
		groups = data.Groups
	}
	address, upn := input.LoginName+"@"+s.config.MailDomain, input.LoginName+"@"+s.config.UPNSuffix
	commandResult, err := s.run(ctx, "ensure_mailbox", map[string]any{
		"LoginName": input.LoginName, "DisplayName": input.DisplayName,
		"UserPrincipalName": upn, "PrimarySmtpAddress": address,
		"InitialPassword": input.InitialPassword, "OrganizationalUnit": s.config.OrganizationalUnit,
		"MailboxDatabase": s.config.MailboxDatabase, "ResetPasswordOnNextLogon": s.config.ResetPasswordOnNextLogon,
	})
	if err != nil {
		return result, err
	}
	var mailbox ensureMailboxData
	if decodeData(commandResult.Data, &mailbox) != nil || mailbox.Created == nil || !guidRE.MatchString(mailbox.MailboxID) ||
		!strings.EqualFold(mailbox.LoginName, input.LoginName) || mailbox.DisplayName != input.DisplayName ||
		!strings.EqualFold(mailbox.UserPrincipalName, upn) || !strings.EqualFold(mailbox.PrimarySMTPAddress, address) {
		return result, invalidResult("ensure_mailbox")
	}
	result = OnboardResult{LoginName: mailbox.LoginName, MailboxID: mailbox.MailboxID, DisplayName: mailbox.DisplayName,
		UserPrincipalName: mailbox.UserPrincipalName, PrimarySMTPAddress: mailbox.PrimarySMTPAddress,
		Created: *mailbox.Created, PasswordApplied: *mailbox.Created, AddedGroups: []string{}, ExistingGroups: []string{}}
	for _, group := range groups {
		commandResult, err = s.run(ctx, "ensure_group_member", map[string]any{
			"GroupIdentity": group.Identity, "MemberIdentity": result.MailboxID,
			"BypassGroupManagerCheck": s.config.BypassGroupManagerCheck,
		})
		if err != nil {
			return result, withTarget(err, group.Identity)
		}
		var membership groupMemberData
		if decodeData(commandResult.Data, &membership) != nil || membership.Added == nil || membership.Group == "" ||
			!strings.EqualFold(membership.GroupID, group.Identity) || !strings.EqualFold(membership.MemberID, result.MailboxID) {
			return result, withTarget(invalidResult("ensure_group_member"), group.Identity)
		}
		if *membership.Added {
			result.AddedGroups = append(result.AddedGroups, membership.Group)
		} else {
			result.ExistingGroups = append(result.ExistingGroups, membership.Group)
		}
	}
	return result, nil
}
func (s *Service) Offboard(ctx context.Context, loginName string) (result OffboardResult, err error) {
	loginName, err = normalizeLoginName(loginName)
	if err != nil {
		return result, err
	}
	if err = s.acquire(loginName); err != nil {
		return result, err
	}
	defer func() { err = s.release(loginName, err) }()
	commandResult, err := s.run(ctx, "discover_user_groups", map[string]any{
		"LoginName": loginName, "UserPrincipalName": loginName + "@" + s.config.UPNSuffix,
	})
	if err != nil {
		return result, err
	}
	var discovery discoverGroupsData
	if decodeData(commandResult.Data, &discovery) != nil || !guidRE.MatchString(discovery.MailboxID) || !validGroups(discovery.Groups) {
		return result, invalidResult("discover_user_groups")
	}
	result = OffboardResult{LoginName: loginName, MailboxID: discovery.MailboxID, RemovedGroups: []string{}}
	for _, group := range discovery.Groups {
		commandResult, err = s.run(ctx, "remove_group_member", map[string]any{
			"GroupIdentity": group.Identity, "MemberIdentity": discovery.MailboxID,
			"BypassGroupManagerCheck": s.config.BypassGroupManagerCheck,
		})
		if err != nil {
			return result, withTarget(err, group.Identity)
		}
		var membership groupMemberData
		if decodeData(commandResult.Data, &membership) != nil || membership.Removed == nil || membership.Group == "" ||
			!strings.EqualFold(membership.GroupID, group.Identity) || !strings.EqualFold(membership.MemberID, discovery.MailboxID) {
			return result, withTarget(invalidResult("remove_group_member"), group.Identity)
		}
		if *membership.Removed {
			result.RemovedGroups = append(result.RemovedGroups, membership.Group)
		}
	}
	sort.Strings(result.RemovedGroups)
	return result, nil
}
func normalizeOnboardInput(input OnboardInput) (OnboardInput, error) {
	loginName, err := normalizeLoginName(input.LoginName)
	if err != nil {
		return OnboardInput{}, err
	}
	input.LoginName = loginName
	input.DisplayName = strings.TrimSpace(input.DisplayName)
	if input.DisplayName == "" {
		return OnboardInput{}, invalidRequest("display_name is required")
	}
	if utf8.RuneCountInString(input.DisplayName) > 256 || containsControl(input.DisplayName) {
		return OnboardInput{}, invalidRequest("display_name must be at most 256 characters and contain no control characters")
	}
	// Empty passwords are only valid for retries of existing matching mailboxes.
	if len(input.InitialPassword) > 1024 || strings.ContainsRune(input.InitialPassword, '\x00') {
		return OnboardInput{}, invalidRequest("initial_password is invalid")
	}
	if len(input.Groups) > maxGroupsPerRequest {
		return OnboardInput{}, invalidRequest("groups must contain at most 100 entries")
	}
	seen := map[string]bool{}
	groups := make([]string, 0, len(input.Groups))
	for _, group := range input.Groups {
		group = strings.TrimSpace(group)
		if group == "" || len(group) > 512 || containsControl(group) {
			return OnboardInput{}, invalidRequest("each groups entry must be non-empty, at most 512 characters, and contain no control characters")
		}
		key := strings.ToLower(group)
		if !seen[key] {
			groups = append(groups, group)
			seen[key] = true
		}
	}
	input.Groups = groups
	return input, nil
}
func normalizeLoginName(loginName string) (string, error) {
	loginName = strings.TrimSpace(loginName)
	if !loginNameRE.MatchString(loginName) || strings.HasSuffix(loginName, ".") || strings.Contains(loginName, "..") {
		return "", invalidRequest("login_name must be 1-20 ASCII characters, start with a letter or digit, and contain only letters, digits, dot, underscore or hyphen; trailing/consecutive dots are forbidden")
	}
	return strings.ToLower(loginName), nil
}
func invalidRequest(message string) *OperationError {
	return newOperationError(CodeInvalidRequest, message, nil)
}
func containsControl(value string) bool { return strings.IndexFunc(value, unicode.IsControl) >= 0 }
func decodeData(data json.RawMessage, destination any) error {
	if len(data) == 0 || string(data) == "null" {
		return fmt.Errorf("result data is empty")
	}
	return json.Unmarshal(data, destination)
}
