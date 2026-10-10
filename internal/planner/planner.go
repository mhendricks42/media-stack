package planner

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"sort"
	"strings"

	"github.com/mhendricks42/media-stack/internal/config"
	"github.com/mhendricks42/media-stack/internal/discovery"
)

const SchemaVersion = "media-stack.plan/v1alpha1"

var componentName = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_.-]*$`)

type Plan struct {
	APIVersion       string      `json:"apiVersion"`
	Kind             string      `json:"kind"`
	Name             string      `json:"name"`
	ID               string      `json:"id"`
	DesiredStateHash string      `json:"desiredStateHash"`
	ActualStateHash  string      `json:"actualStateHash"`
	Platform         string      `json:"platform"`
	Blockers         []string    `json:"blockers,omitempty"`
	Operations       []Operation `json:"operations"`
}

type Operation struct {
	ID                string   `json:"id"`
	Component         string   `json:"component"`
	Action            string   `json:"action"`
	Current           string   `json:"current"`
	Desired           string   `json:"desired"`
	Mutating          bool     `json:"mutating"`
	RestartImpact     string   `json:"restartImpact"`
	Destructive       bool     `json:"destructive"`
	SecuritySensitive bool     `json:"securitySensitive"`
	Prerequisites     []string `json:"prerequisites,omitempty"`
	Verification      string   `json:"verification"`
	Rollback          string   `json:"rollback"`
	ScriptCommand     string   `json:"scriptCommand,omitempty"`
	ScriptArguments   []string `json:"scriptArguments,omitempty"`
}

func Build(state config.State, facts discovery.Facts) (Plan, error) {
	if err := state.Validate(); err != nil {
		return Plan{}, err
	}
	desiredHash, err := hashValue(state)
	if err != nil {
		return Plan{}, err
	}
	actualHash, err := discovery.Hash(facts)
	if err != nil {
		return Plan{}, err
	}
	p := Plan{
		APIVersion: SchemaVersion, Kind: "DeploymentPlan", Name: state.Metadata.Name,
		DesiredStateHash: desiredHash, ActualStateHash: actualHash, Platform: state.Spec.Platform,
		Operations: make([]Operation, 0, 5),
	}
	if !facts.DockerAvailable {
		p.Blockers = append(p.Blockers, "Docker CLI is unavailable; install Docker Engine or Docker Desktop")
	} else if !facts.ComposeAvailable {
		p.Blockers = append(p.Blockers, "Docker Compose v2 is unavailable; install the docker compose plugin")
	}
	if facts.EnvExists && facts.EnvPlatform != "" && facts.EnvPlatform != state.Spec.Platform {
		p.Blockers = append(p.Blockers, fmt.Sprintf(".env targets %s; adopt or remove it before targeting %s", facts.EnvPlatform, state.Spec.Platform))
	}
	envCurrent := "existing compatibility environment"
	if !facts.EnvExists {
		envCurrent = "absent"
	}
	env := operation("environment", "CONFIGURE", envCurrent, "non-secret desired-state values", true, "", ".env contains desired non-secret values", "restore the previous .env", "configure-env", nil)
	p.Operations = append(p.Operations, env)
	up := operation("compose", "START", "discovered runtime", "desired containers running", true, env.ID, "docker compose ps succeeds", "run stack down", "up", nil)
	setup := operation("storage", "RECONCILE", state.Spec.Storage.Root, "media and download directory tree", true, up.ID, "required paths exist on one data root", "created empty directories may be removed", "setup-data", nil)
	bootstrap := operation("applications", "CONFIGURE", "existing application configuration", "desired integrations configured", true, setup.ID, "bootstrap exits successfully and integrations verify", "restore application backup where supported", "bootstrap", nil)
	verify := operation("deployment", "VERIFY", "unverified", "VPN, containers, and integrations healthy", false, bootstrap.ID, "existing verification script succeeds", "no mutation", "verify", nil)
	p.Operations = append(p.Operations, up, setup, bootstrap, verify)
	sort.Strings(p.Blockers)
	idMaterial := struct {
		Desired string      `json:"desired"`
		Actual  string      `json:"actual"`
		Ops     []Operation `json:"operations"`
	}{desiredHash, actualHash, p.Operations}
	p.ID, err = hashValue(idMaterial)
	if err != nil {
		return Plan{}, err
	}
	p.ID = p.ID[:16]
	return p, nil
}

func BuildRepair(state config.State, facts discovery.Facts, component string) (Plan, error) {
	if !componentName.MatchString(component) {
		return Plan{}, fmt.Errorf("invalid component name %q", component)
	}
	if err := state.Validate(); err != nil {
		return Plan{}, err
	}
	desiredHash, err := hashValue(state)
	if err != nil {
		return Plan{}, err
	}
	actualHash, err := discovery.Hash(facts)
	if err != nil {
		return Plan{}, err
	}
	restart := operation(component, "RESTART", "unhealthy or drifted", "running with current desired configuration", true, "", "component is present in docker compose ps", "inspect logs and retry; no data rollback is performed", "restart", []string{component})
	verify := operation("deployment", "VERIFY", "repair applied", "deployment verification succeeds", false, restart.ID, "existing verification script succeeds", "no mutation", "verify", nil)
	p := Plan{
		APIVersion:       SchemaVersion,
		Kind:             "DeploymentPlan",
		Name:             state.Metadata.Name + "-repair-" + component,
		DesiredStateHash: desiredHash,
		ActualStateHash:  actualHash,
		Platform:         state.Spec.Platform,
		Operations:       []Operation{restart, verify},
	}
	if !facts.DockerAvailable {
		p.Blockers = append(p.Blockers, "Docker CLI is unavailable; install Docker Engine or Docker Desktop")
	} else if !facts.ComposeAvailable {
		p.Blockers = append(p.Blockers, "Docker Compose v2 is unavailable; install the docker compose plugin")
	}
	p.ID, err = hashValue(struct {
		Desired string      `json:"desired"`
		Actual  string      `json:"actual"`
		Ops     []Operation `json:"operations"`
	}{desiredHash, actualHash, p.Operations})
	if err != nil {
		return Plan{}, err
	}
	p.ID = p.ID[:16]
	return p, nil
}

func operation(component, action, current, desired string, mutating bool, prerequisite, verification, rollback, command string, arguments []string) Operation {
	op := Operation{
		Component: component, Action: action, Current: current, Desired: desired,
		Mutating: mutating, RestartImpact: "none", Verification: verification,
		Rollback: rollback, ScriptCommand: command, ScriptArguments: arguments,
	}
	if mutating && component != "environment" && component != "storage" {
		op.RestartImpact = "affected services"
	}
	if prerequisite != "" {
		op.Prerequisites = []string{prerequisite}
	}
	op.ID, _ = hashValue(struct {
		Component string   `json:"component"`
		Action    string   `json:"action"`
		Desired   string   `json:"desired"`
		Command   string   `json:"command"`
		Arguments []string `json:"arguments"`
	}{component, action, desired, command, arguments})
	op.ID = component + "-" + op.ID[:12]
	return op
}

func Save(path string, p Plan) error {
	data, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	return os.WriteFile(path, data, 0o600)
}

func Load(path string) (Plan, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Plan{}, err
	}
	var p Plan
	dec := json.NewDecoder(strings.NewReader(string(data)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&p); err != nil {
		return Plan{}, fmt.Errorf("decode plan: %w", err)
	}
	if p.APIVersion != SchemaVersion || p.Kind != "DeploymentPlan" || p.ID == "" {
		return Plan{}, errors.New("unsupported or invalid plan")
	}
	return p, nil
}

func CheckFresh(p Plan, state config.State, facts discovery.Facts) error {
	desired, err := hashValue(state)
	if err != nil {
		return err
	}
	actual, err := discovery.Hash(facts)
	if err != nil {
		return err
	}
	var stale []string
	if p.DesiredStateHash != desired {
		stale = append(stale, "desired state changed")
	}
	if p.ActualStateHash != actual {
		stale = append(stale, "host or actual state changed")
	}
	if len(stale) != 0 {
		return fmt.Errorf("stale plan: %s; run media-stack plan again", strings.Join(stale, " and "))
	}
	return nil
}

func WriteText(w io.Writer, p Plan) error {
	if _, err := fmt.Fprintf(w, "Deployment plan: %s (%s)\n\nHost\n  Target: %s\n\nChanges\n", p.Name, p.ID, p.Platform); err != nil {
		return err
	}
	for _, op := range p.Operations {
		if _, err := fmt.Fprintf(w, "  %-10s %-14s %s\n", op.Action, op.Component, op.Desired); err != nil {
			return err
		}
	}
	if len(p.Blockers) != 0 {
		if _, err := fmt.Fprintln(w, "\nBlockers"); err != nil {
			return err
		}
		for _, blocker := range p.Blockers {
			if _, err := fmt.Fprintln(w, "  -", blocker); err != nil {
				return err
			}
		}
	}
	return nil
}

func hashValue(v any) (string, error) {
	data, err := json.Marshal(v)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:]), nil
}
