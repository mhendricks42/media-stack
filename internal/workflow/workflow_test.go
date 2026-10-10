package workflow

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/mhendricks42/media-stack/internal/config"
	"github.com/mhendricks42/media-stack/internal/discovery"
	"github.com/mhendricks42/media-stack/internal/planner"
	"github.com/mhendricks42/media-stack/internal/scripts"
)

type fakeAdapter struct {
	failCommand string
	executed    []string
}

func (f *fakeAdapter) Execute(_ context.Context, command string, _ ...string) (scripts.Result, error) {
	f.executed = append(f.executed, command)
	if command == f.failCommand {
		return scripts.Result{Command: command, ExitCode: 7, Output: "PASSWORD=hidden"}, errors.New("PASSWORD=hidden")
	}
	return scripts.Result{Command: command, Output: "ok"}, nil
}

func (f *fakeAdapter) Verify(_ context.Context, _ planner.Operation) (string, error) {
	return "verified", nil
}

func workflowState() config.State {
	state := config.Defaults()
	state.Spec.Platform = "linux"
	state.Spec.Secrets.References["vpnUsername"] = "user-reference"
	state.Spec.Secrets.References["vpnPassword"] = "password-reference"
	return state
}

func TestInterruptedApplyResumesAndRedacts(t *testing.T) {
	state := workflowState()
	facts := discovery.Facts{OS: "linux", Architecture: "amd64", RepositoryRoot: "/repo", DockerAvailable: true, ComposeAvailable: true}
	p, err := planner.Build(state, facts)
	if err != nil {
		t.Fatal(err)
	}
	first := &fakeAdapter{failCommand: "bootstrap"}
	engine := New(t.TempDir(), first)
	now := time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC)
	engine.Now = func() time.Time { return now }
	path, err := engine.Apply(context.Background(), p)
	if err == nil {
		t.Fatal("expected interrupted apply")
	}
	data, readErr := os.ReadFile(path)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if strings.Contains(string(data), "PASSWORD=hidden") {
		t.Fatal("journal leaked command secret")
	}

	second := &fakeAdapter{}
	resumer := New(engine.Root, second)
	resumer.Now = engine.Now
	if err := resumer.Resume(context.Background(), path, state); err != nil {
		t.Fatal(err)
	}
	journal, err := LoadJournal(path)
	if err != nil {
		t.Fatal(err)
	}
	if journal.Status != Succeeded {
		t.Fatalf("journal status is %s", journal.Status)
	}
	if strings.Join(second.executed, ",") != "bootstrap,verify" {
		t.Fatalf("resume replayed completed mutations: %#v", second.executed)
	}
}

func TestResumeRejectsChangedDesiredState(t *testing.T) {
	state := workflowState()
	facts := discovery.Facts{OS: "linux", Architecture: "amd64", RepositoryRoot: "/repo", DockerAvailable: true, ComposeAvailable: true}
	p, _ := planner.Build(state, facts)
	engine := New(t.TempDir(), &fakeAdapter{failCommand: "bootstrap"})
	path, _ := engine.Apply(context.Background(), p)
	state.Metadata.Name = "changed"
	err := engine.Resume(context.Background(), path, state)
	if err == nil || !strings.Contains(err.Error(), "desired state changed") {
		t.Fatalf("expected changed state rejection, got %v", err)
	}
}
