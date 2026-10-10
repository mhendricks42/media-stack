package scripts

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"

	"github.com/mhendricks42/media-stack/internal/config"
	"github.com/mhendricks42/media-stack/internal/planner"
	"github.com/mhendricks42/media-stack/internal/secrets"
)

var componentName = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_.-]*$`)

type Result struct {
	Command  string `json:"command"`
	ExitCode int    `json:"exitCode"`
	Output   string `json:"output,omitempty"`
}

type Runner interface {
	Run(context.Context, string, ...string) ([]byte, error)
}

type ExecRunner struct {
	Dir string
}

func (r ExecRunner) Run(ctx context.Context, name string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = r.Dir
	return cmd.CombinedOutput()
}

type Adapter struct {
	Root   string
	HostOS string
	Runner Runner
	State  *config.State
}

func New(root string) *Adapter {
	return &Adapter{Root: root, HostOS: runtime.GOOS, Runner: ExecRunner{Dir: root}}
}

func NewForState(root string, state config.State) *Adapter {
	adapter := New(root)
	adapter.State = &state
	return adapter
}

func (a *Adapter) Arguments(command string, arguments ...string) (string, []string, error) {
	switch a.HostOS {
	case "windows":
		shell := "powershell.exe"
		if _, err := exec.LookPath(shell); err != nil {
			shell = "pwsh"
		}
		args := []string{"-NoProfile", "-ExecutionPolicy", "Bypass", "-File", filepath.Join(a.Root, "stack.ps1"), command}
		return shell, append(args, arguments...), nil
	case "linux":
		args := []string{filepath.Join(a.Root, "stack.sh"), command}
		return "bash", append(args, arguments...), nil
	default:
		return "", nil, fmt.Errorf("unsupported host platform %q", a.HostOS)
	}
}

func (a *Adapter) Execute(ctx context.Context, command string, arguments ...string) (Result, error) {
	if command == "configure-env" {
		if a.State == nil {
			return Result{Command: command, ExitCode: 1}, errors.New("desired state is required to configure .env")
		}
		if err := config.WriteEnv(a.Root, *a.State); err != nil {
			return Result{Command: command, ExitCode: 1}, fmt.Errorf("configure .env: %w", err)
		}
		return Result{Command: command, Output: ".env updated with non-secret desired-state values"}, nil
	}
	name, args, err := a.Arguments(command, arguments...)
	if err != nil {
		return Result{}, err
	}
	output, runErr := a.Runner.Run(ctx, name, args...)
	result := Result{Command: command, Output: bounded(secrets.RedactText(string(output)), 16*1024)}
	if runErr != nil {
		result.ExitCode = 1
		if exit, ok := runErr.(*exec.ExitError); ok {
			result.ExitCode = exit.ExitCode()
		}
		return result, fmt.Errorf("%s failed with exit code %d: %s", command, result.ExitCode, strings.TrimSpace(result.Output))
	}
	return result, nil
}

func (a *Adapter) Logs(ctx context.Context, component string, w io.Writer) error {
	if !componentName.MatchString(component) {
		return fmt.Errorf("invalid component name %q", component)
	}
	result, err := a.Execute(ctx, "logs", component)
	if result.Output != "" {
		_, _ = io.Copy(w, bytes.NewBufferString(result.Output))
	}
	return err
}

func (a *Adapter) Verify(ctx context.Context, op planner.Operation) (string, error) {
	switch op.ScriptCommand {
	case "use":
		path := filepath.Join(a.Root, ".env")
		if _, err := os.Stat(path); err != nil {
			return "generated .env is missing", err
		}
		return ".env exists", nil
	case "setup-data":
		return "setup command completed", nil
	case "configure-env":
		path := filepath.Join(a.Root, ".env")
		data, err := os.ReadFile(path)
		if err != nil {
			return "configured .env is missing", err
		}
		if a.State == nil {
			return "", errors.New("desired state is required to verify .env")
		}
		expected, err := config.RenderEnv(data, *a.State)
		if err != nil {
			return "", err
		}
		if !bytes.Equal(data, expected) {
			return "", errors.New(".env does not match desired non-secret values")
		}
		return ".env matches desired non-secret values", nil
	case "up":
		result, err := a.Execute(ctx, "ps")
		return result.Output, err
	case "restart":
		result, err := a.Execute(ctx, "ps")
		return result.Output, err
	case "bootstrap":
		result, err := a.Execute(ctx, "verify")
		return result.Output, err
	case "verify":
		return "verification command completed", nil
	default:
		return "", fmt.Errorf("no verifier for %s", op.ID)
	}
}

func bounded(value string, size int) string {
	if len(value) <= size {
		return value
	}
	return value[len(value)-size:]
}
