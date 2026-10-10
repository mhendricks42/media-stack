package planner

import (
	"strings"
	"testing"

	"github.com/mhendricks42/media-stack/internal/config"
	"github.com/mhendricks42/media-stack/internal/discovery"
)

func testState() config.State {
	state := config.Defaults()
	state.Spec.Platform = "linux"
	state.Spec.Secrets.References["vpnUsername"] = "vpn-user"
	state.Spec.Secrets.References["vpnPassword"] = "vpn-password"
	return state
}

func TestBuildDeterministic(t *testing.T) {
	facts := discovery.Facts{OS: "linux", Architecture: "amd64", RepositoryRoot: "/repo", DockerAvailable: true, ComposeAvailable: true}
	a, err := Build(testState(), facts)
	if err != nil {
		t.Fatal(err)
	}

	b, err := Build(testState(), facts)
	if err != nil {
		t.Fatal(err)
	}
	if a.ID != b.ID || len(a.Operations) != len(b.Operations) {
		t.Fatalf("plans differ: %#v %#v", a, b)
	}
	for i := range a.Operations {
		if a.Operations[i].ID != b.Operations[i].ID {
			t.Fatalf("operation IDs differ at %d", i)
		}
	}
}

func TestNewDeploymentConfiguresEnvFromTargetTemplate(t *testing.T) {
	facts := discovery.Facts{OS: "linux", Architecture: "amd64", RepositoryRoot: "/repo", DockerAvailable: true, ComposeAvailable: true}
	p, err := Build(testState(), facts)
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Operations) < 1 ||
		p.Operations[0].ScriptCommand != "configure-env" ||
		len(p.Operations[0].Prerequisites) != 0 {
		t.Fatalf("environment operations are not ordered safely: %#v", p.Operations)
	}
}

func TestStalePlanDetection(t *testing.T) {
	facts := discovery.Facts{OS: "linux", Architecture: "amd64", RepositoryRoot: "/repo", DockerAvailable: true, ComposeAvailable: true}
	p, err := Build(testState(), facts)
	if err != nil {
		t.Fatal(err)
	}
	changed := testState()
	changed.Metadata.Name = "changed"
	if err := CheckFresh(p, changed, facts); err == nil || !strings.Contains(err.Error(), "desired state changed") {
		t.Fatalf("expected stale desired state, got %v", err)
	}
	facts.EnvExists = true
	if err := CheckFresh(p, testState(), facts); err == nil || !strings.Contains(err.Error(), "actual state changed") {
		t.Fatalf("expected stale facts, got %v", err)
	}
}

func TestPlanBlocksTargetReplacement(t *testing.T) {
	facts := discovery.Facts{
		OS: "windows", Architecture: "amd64", RepositoryRoot: `C:\repo`,
		DockerAvailable: true, ComposeAvailable: true, EnvExists: true, EnvPlatform: "windows",
	}
	p, err := Build(testState(), facts)
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Blockers) != 1 || !strings.Contains(p.Blockers[0], "adopt or remove") {
		t.Fatalf("expected target replacement blocker, got %#v", p.Blockers)
	}
}

func TestBuildStartsContainersBeforeContainerBackedStorageSetup(t *testing.T) {
	facts := discovery.Facts{
		OS: "linux", Architecture: "amd64", RepositoryRoot: "/repo",
		DockerAvailable: true, ComposeAvailable: true, EnvExists: true, EnvPlatform: "linux",
	}
	p, err := Build(testState(), facts)
	if err != nil {
		t.Fatal(err)
	}
	var commands []string
	for _, operation := range p.Operations {
		commands = append(commands, operation.ScriptCommand)
	}
	got := strings.Join(commands, ",")
	if got != "configure-env,up,setup-data,bootstrap,verify" {
		t.Fatalf("unsafe operation order: %s", got)
	}
}

func TestBuildRepairCreatesReviewedRestart(t *testing.T) {
	facts := discovery.Facts{OS: "linux", Architecture: "amd64", RepositoryRoot: "/repo", DockerAvailable: true, ComposeAvailable: true}
	p, err := BuildRepair(testState(), facts, "sonarr")
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Operations) != 2 ||
		p.Operations[0].ScriptCommand != "restart" ||
		len(p.Operations[0].ScriptArguments) != 1 ||
		p.Operations[0].ScriptArguments[0] != "sonarr" ||
		p.Operations[1].ScriptCommand != "verify" {
		t.Fatalf("unexpected repair plan: %#v", p.Operations)
	}
	if _, err := BuildRepair(testState(), facts, "../config"); err == nil {
		t.Fatal("expected invalid component rejection")
	}
}
