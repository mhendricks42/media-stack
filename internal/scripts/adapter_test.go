package scripts

import (
	"context"
	"errors"
	"path/filepath"
	"strings"
	"testing"
)

type fakeRunner struct {
	name string
	args []string
	out  []byte
	err  error
}

func (f *fakeRunner) Run(_ context.Context, name string, args ...string) ([]byte, error) {
	f.name, f.args = name, append([]string(nil), args...)
	return f.out, f.err
}

func TestLinuxArguments(t *testing.T) {
	a := Adapter{Root: "/repo", HostOS: "linux"}
	name, args, err := a.Arguments("use", "linux")
	if err != nil {
		t.Fatal(err)
	}
	expected := filepath.Join("/repo", "stack.sh") + " use linux"
	if name != "bash" || strings.Join(args, " ") != expected {
		t.Fatalf("unexpected command: %s %#v", name, args)
	}
}

func TestWindowsArguments(t *testing.T) {
	a := Adapter{Root: `C:\repo`, HostOS: "windows"}
	_, args, err := a.Arguments("doctor")
	if err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(args, " ")
	if !strings.Contains(joined, "stack.ps1") || !strings.HasSuffix(joined, " doctor") {
		t.Fatalf("unexpected arguments: %#v", args)
	}
}

func TestExecuteRedactsOutput(t *testing.T) {
	runner := &fakeRunner{out: []byte("VPN_PASS=hunter2\n"), err: errors.New("failed")}
	a := Adapter{Root: "/repo", HostOS: "linux", Runner: runner}
	result, err := a.Execute(context.Background(), "doctor")
	if err == nil {
		t.Fatal("expected error")
	}
	if strings.Contains(result.Output, "hunter2") || strings.Contains(err.Error(), "hunter2") {
		t.Fatalf("secret leaked: %#v %v", result, err)
	}
}

func TestLogsRejectsInvalidComponent(t *testing.T) {
	a := Adapter{Root: "/repo", HostOS: "linux", Runner: &fakeRunner{}}
	if err := a.Logs(context.Background(), "../secret", &strings.Builder{}); err == nil {
		t.Fatal("expected invalid component error")
	}
}
