package exchange

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/m15608293998-arch/exchange-automation/internal/automation"
)

const maxGroupsPerRequest = 100

var (
	loginNameRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,19}$`)
	domainRE    = regexp.MustCompile(`^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$`)
)

type Config struct {
	MailDomain               string
	OrganizationalUnit       string
	MailboxDatabase          string
	ResetPasswordOnNextLogon bool
	BypassGroupManagerCheck  bool
}

type Service struct {
	executor automation.Executor
	config   Config
}

type OnboardInput struct {
	LoginName       string   `json:"login_name"`
	DisplayName     string   `json:"display_name"`
	InitialPassword string   `json:"initial_password"`
	Groups          []string `json:"groups"`
}

type OnboardResult struct {
	LoginName          string   `json:"login_name"`
	DisplayName        string   `json:"display_name"`
	PrimarySMTPAddress string   `json:"primary_smtp_address"`
	Created            bool     `json:"created"`
	AddedGroups        []string `json:"added_groups"`
	ExistingGroups     []string `json:"existing_groups"`
}

type OffboardResult struct {
	LoginName     string   `json:"login_name"`
	RemovedGroups []string `json:"removed_groups"`
}

type ensureMailboxData struct {
	Created            bool   `json:"created"`
	LoginName          string `json:"login_name"`
	DisplayName        string `json:"display_name"`
	PrimarySMTPAddress string `json:"primary_smtp_address"`
}

type groupMemberData struct {
	Group   string `json:"group"`
	Added   bool   `json:"added"`
	Removed bool   `json:"removed"`
}

type discoveredGroup struct {
	Identity string `json:"identity"`
	Label    string `json:"label"`
}

type discoverGroupsData struct {
	Groups []discoveredGroup `json:"groups"`
}

func NewService(executor automation.Executor, config Config) (*Service, error) {
	if executor == nil {
		return nil, fmt.Errorf("automation executor must not be nil")
	}

	config.MailDomain = strings.ToLower(strings.TrimPrefix(strings.TrimSpace(config.MailDomain), "@"))
	if !domainRE.MatchString(config.MailDomain) {
		return nil, fmt.Errorf("invalid Exchange mail domain %q", config.MailDomain)
	}

	return &Service{executor: executor, config: config}, nil
}

func (s *Service) Onboard(ctx context.Context, input OnboardInput) (OnboardResult, error) {
	input, err := normalizeOnboardInput(input)
	if err != nil {
		return OnboardResult{}, err
	}

	primaryAddress := input.LoginName + "@" + s.config.MailDomain
	result := OnboardResult{
		LoginName:          input.LoginName,
		DisplayName:        input.DisplayName,
		PrimarySMTPAddress: primaryAddress,
		AddedGroups:        []string{},
		ExistingGroups:     []string{},
	}

	commandResult, err := s.executor.Execute(ctx, "ensure_mailbox", map[string]any{
		"LoginName":                input.LoginName,
		"DisplayName":              input.DisplayName,
		"UserPrincipalName":        primaryAddress,
		"PrimarySmtpAddress":       primaryAddress,
		"InitialPassword":          input.InitialPassword,
		"OrganizationalUnit":       s.config.OrganizationalUnit,
		"MailboxDatabase":          s.config.MailboxDatabase,
		"ResetPasswordOnNextLogon": s.config.ResetPasswordOnNextLogon,
	})
	if err != nil {
		return result, newOperationError(CodeAutomationFailure, "Ansible could not execute the mailbox operation", err)
	}
	if !commandResult.OK {
		return result, newOperationError(commandResult.Code, commandResult.Message, nil)
	}

	var mailbox ensureMailboxData
	if err := decodeData(commandResult.Data, &mailbox); err != nil {
		return result, newOperationError(CodeAutomationFailure, "Exchange returned an invalid mailbox result", err)
	}
	result.Created = mailbox.Created
	if mailbox.LoginName != "" {
		result.LoginName = mailbox.LoginName
	}
	if mailbox.DisplayName != "" {
		result.DisplayName = mailbox.DisplayName
	}
	if mailbox.PrimarySMTPAddress != "" {
		result.PrimarySMTPAddress = mailbox.PrimarySMTPAddress
	}

	for _, group := range input.Groups {
		commandResult, err = s.executor.Execute(ctx, "ensure_group_member", map[string]any{
			"GroupIdentity":           group,
			"MemberIdentity":          primaryAddress,
			"BypassGroupManagerCheck": s.config.BypassGroupManagerCheck,
		})
		if err != nil {
			return result, newOperationError(CodeAutomationFailure, "Ansible could not add the mailbox to a distribution group", err)
		}
		if !commandResult.OK {
			return result, newOperationError(commandResult.Code, commandResult.Message, nil)
		}

		var membership groupMemberData
		if err := decodeData(commandResult.Data, &membership); err != nil {
			return result, newOperationError(CodeAutomationFailure, "Exchange returned an invalid group membership result", err)
		}
		if membership.Group == "" {
			membership.Group = group
		}
		if membership.Added {
			result.AddedGroups = append(result.AddedGroups, membership.Group)
		} else {
			result.ExistingGroups = append(result.ExistingGroups, membership.Group)
		}
	}

	return result, nil
}

func (s *Service) Offboard(ctx context.Context, loginName string) (OffboardResult, error) {
	loginName, err := normalizeLoginName(loginName)
	if err != nil {
		return OffboardResult{}, err
	}

	result := OffboardResult{LoginName: loginName, RemovedGroups: []string{}}
	commandResult, err := s.executor.Execute(ctx, "discover_user_groups", map[string]any{
		"LoginName": loginName,
	})
	if err != nil {
		return result, newOperationError(CodeAutomationFailure, "Ansible could not discover distribution group memberships", err)
	}
	if !commandResult.OK {
		return result, newOperationError(commandResult.Code, commandResult.Message, nil)
	}

	var discovery discoverGroupsData
	if err := decodeData(commandResult.Data, &discovery); err != nil {
		return result, newOperationError(CodeAutomationFailure, "Exchange returned an invalid group discovery result", err)
	}

	for _, group := range discovery.Groups {
		commandResult, err = s.executor.Execute(ctx, "remove_group_member", map[string]any{
			"GroupIdentity":           group.Identity,
			"MemberIdentity":          loginName,
			"BypassGroupManagerCheck": s.config.BypassGroupManagerCheck,
		})
		if err != nil {
			return result, newOperationError(CodeAutomationFailure, "Ansible could not remove the mailbox from a distribution group", err)
		}
		if !commandResult.OK {
			return result, newOperationError(commandResult.Code, commandResult.Message, nil)
		}

		var membership groupMemberData
		if err := decodeData(commandResult.Data, &membership); err != nil {
			return result, newOperationError(CodeAutomationFailure, "Exchange returned an invalid group removal result", err)
		}
		if membership.Removed {
			label := membership.Group
			if label == "" {
				label = group.Label
			}
			result.RemovedGroups = append(result.RemovedGroups, label)
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
	if input.InitialPassword == "" {
		return OnboardInput{}, invalidRequest("initial_password is required")
	}
	if len(input.InitialPassword) > 1024 || strings.ContainsRune(input.InitialPassword, '\x00') {
		return OnboardInput{}, invalidRequest("initial_password is invalid")
	}
	if len(input.Groups) > maxGroupsPerRequest {
		return OnboardInput{}, invalidRequest("groups must contain at most 100 entries")
	}

	seen := make(map[string]struct{}, len(input.Groups))
	groups := make([]string, 0, len(input.Groups))
	for _, group := range input.Groups {
		group = strings.TrimSpace(group)
		if group == "" || len(group) > 512 || containsControl(group) {
			return OnboardInput{}, invalidRequest("each groups entry must be non-empty, at most 512 characters, and contain no control characters")
		}
		key := strings.ToLower(group)
		if _, exists := seen[key]; exists {
			continue
		}
		seen[key] = struct{}{}
		groups = append(groups, group)
	}
	input.Groups = groups
	return input, nil
}

func normalizeLoginName(loginName string) (string, error) {
	loginName = strings.TrimSpace(loginName)
	if !loginNameRE.MatchString(loginName) {
		return "", invalidRequest("login_name must be 1-20 characters and contain only letters, numbers, dot, underscore, or hyphen")
	}
	return strings.ToLower(loginName), nil
}

func invalidRequest(message string) *OperationError {
	return newOperationError(CodeInvalidRequest, message, nil)
}

func containsControl(value string) bool {
	return strings.IndexFunc(value, unicode.IsControl) >= 0
}

func decodeData(data json.RawMessage, destination any) error {
	if len(data) == 0 || string(data) == "null" {
		return fmt.Errorf("result data is empty")
	}
	return json.Unmarshal(data, destination)
}
