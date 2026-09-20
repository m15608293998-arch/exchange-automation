package ansible

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

// Uses the real repository playbook and Ansible templater. Only the Windows
// action is replaced: no remote host or real credentials are involved.
func TestRealAnsiblePreservesUntrustedParameters(t *testing.T) {
	binary, err := exec.LookPath("ansible-playbook")
	if err != nil {
		t.Skip("ansible-playbook is not installed")
	}
	root := t.TempDir()
	collection := filepath.Join(root, "collections", "ansible_collections", "ansible", "windows")
	for _, directory := range []string{"plugins/action", "plugins/modules"} {
		if err := os.MkdirAll(filepath.Join(collection, directory), 0700); err != nil {
			t.Fatal(err)
		}
	}
	action := `import json
from ansible.plugins.action import ActionBase
class ActionModule(ActionBase):
    def run(self, tmp=None, task_vars=None):
        args = self._task.args
        payload = {"ok": True, "data": {"parameters": args["parameters"], "sensitive": args.get("sensitive_parameters", [])}}
        return {"changed": False, "output": [json.dumps(payload)]}
`
	if err := os.WriteFile(filepath.Join(collection, "plugins/action/win_powershell.py"), []byte(action), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(collection, "plugins/modules/win_powershell.py"), []byte("DOCUMENTATION = ''\n"), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("ANSIBLE_COLLECTIONS_PATHS", filepath.Join(root, "collections"))
	inventory := filepath.Join(root, "inventory.yml")
	if err := os.WriteFile(inventory, []byte("all:\n  children:\n    exchange_servers:\n      hosts:\n        localhost:\n          ansible_connection: local\n"), 0600); err != nil {
		t.Fatal(err)
	}
	playbook, err := filepath.Abs("../../automation/playbooks/exchange_operation.yml")
	if err != nil {
		t.Fatal(err)
	}
	runner, err := NewRunner(binary, inventory, playbook, filepath.Join(root, "tmp"))
	if err != nil {
		t.Fatal(err)
	}
	name := "{{ lookup('ansible.builtin.pipe', 'printf THIS_MUST_NOT_EXECUTE') }}"
	password := "{{ 7 * 7 }}中文$'\"\\"
	groups := []string{"{{ lookup('env', 'PATH') }}", "{% if true %}x{% endif %}"}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	result, err := runner.Execute(ctx, "ensure_mailbox", map[string]any{
		"LoginName": "reviewprobe", "DisplayName": name, "InitialPassword": password, "GroupIdentities": groups,
	})
	if err != nil {
		t.Fatal(err)
	}
	var data struct {
		Parameters struct {
			DisplayName     string
			GroupIdentities []string
		}
		Sensitive []struct {
			Name  string
			Value string
		}
	}
	if err := json.Unmarshal(result.Data, &data); err != nil {
		t.Fatal(err)
	}
	if data.Parameters.DisplayName != name || !reflect.DeepEqual(data.Parameters.GroupIdentities, groups) ||
		len(data.Sensitive) != 1 || data.Sensitive[0].Value != password {
		t.Fatal("untrusted data was changed during real Ansible templating")
	}
	// Password-less retries must omit sensitive_parameters, not send an empty SecureString.
	result, err = runner.Execute(ctx, "ensure_mailbox", map[string]any{"InitialPassword": ""})
	if err != nil {
		t.Fatal(err)
	}
	data.Sensitive = nil
	if err := json.Unmarshal(result.Data, &data); err != nil || len(data.Sensitive) != 0 {
		t.Fatal("empty password was not omitted")
	}
}
