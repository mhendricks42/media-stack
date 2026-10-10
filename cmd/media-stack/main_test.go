package main

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/mhendricks42/media-stack/internal/config"
	"github.com/mhendricks42/media-stack/internal/scripts"
)

type fakeExecutor struct {
	commands []string
	fail     string
}

func (f *fakeExecutor) Execute(_ context.Context, command string, _ ...string) (scripts.Result, error) {
	f.commands = append(f.commands, command)
	if command == f.fail {
		return scripts.Result{Command: command, ExitCode: 1}, errors.New("failed")
	}
	return scripts.Result{Command: command}, nil
}

func TestConfigureWritesSelectedProfile(t *testing.T) {
	root := t.TempDir()
	var output bytes.Buffer
	a := app{in: strings.NewReader(""), out: &output, errOut: &output, cwd: root}
	err := a.configure(root, []string{
		"--profile", "usenet-only",
		"--platform", "linux",
		"--name", "news",
		"--data-root", "/srv/media",
		"--write", "state.yaml",
	})
	if err != nil {
		t.Fatal(err)
	}
	state, err := config.Load(filepath.Join(root, "state.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if state.Metadata.Name != "news" || state.Spec.Storage.Root != "/srv/media" ||
		state.Spec.Features.Torrents || !state.Spec.Features.Usenet {
		t.Fatalf("unexpected configured state: %#v", state)
	}
}

func TestGuidedConfigureUsesDefaults(t *testing.T) {
	root := t.TempDir()
	var output bytes.Buffer
	a := app{in: strings.NewReader("\nlinux\nhome\n/srv/data\n"), out: &output, errOut: &output}
	if err := a.configure(root, nil); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.String(), "apiVersion: media-stack.dev/v1alpha1") ||
		!strings.Contains(output.String(), "root: /srv/data") {
		t.Fatalf("unexpected guided output: %s", output.String())
	}
}

func TestUpdateRequiresExplicitApproval(t *testing.T) {
	var output bytes.Buffer
	a := app{out: &output, errOut: &output}
	err := a.update(context.Background(), t.TempDir(), nil)
	if err == nil || !strings.Contains(err.Error(), "explicit --yes") {
		t.Fatalf("expected approval error, got %v", err)
	}
}

func TestMaintenanceStopsAfterFailure(t *testing.T) {
	executor := &fakeExecutor{fail: "backup"}
	err := executeCommands(context.Background(), executor, []maintenanceCommand{{name: "backup"}, {name: "pull"}}, nil)
	if err == nil {
		t.Fatal("expected failure")
	}

	if strings.Join(executor.commands, ",") != "backup" {
		t.Fatalf("pull ran after failed backup: %#v", executor.commands)
	}
}

func TestUpdateCommandOrder(t *testing.T) {
	executor := &fakeExecutor{}
	err := executeCommands(context.Background(), executor, []maintenanceCommand{{name: "backup"}, {name: "pull"}}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(executor.commands, ",") != "backup,pull" {
		t.Fatalf("unexpected update order: %#v", executor.commands)
	}
}

func TestRestoreAndRollbackFailExplicitly(t *testing.T) {
	root := t.TempDir()
	for _, name := range []string{"docker-compose.yml", "stack.sh"} {
		if err := os.WriteFile(filepath.Join(root, name), []byte(""), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	a := app{in: strings.NewReader(""), out: &bytes.Buffer{}, errOut: &bytes.Buffer{}, cwd: root}
	for _, command := range []string{"restore", "rollback"} {
		err := a.run(context.Background(), []string{command})
		if err == nil || !strings.Contains(err.Error(), "unsupported") {
			t.Fatalf("%s should fail explicitly, got %v", command, err)
		}
	}
}
