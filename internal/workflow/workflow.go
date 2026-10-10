package workflow

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"

	"github.com/mhendricks42/media-stack/internal/config"
	"github.com/mhendricks42/media-stack/internal/planner"
	"github.com/mhendricks42/media-stack/internal/scripts"
	"github.com/mhendricks42/media-stack/internal/secrets"
)

type Status string

const (
	Pending   Status = "pending"
	Running   Status = "running"
	Succeeded Status = "success"
	Failed    Status = "failure"
	Blocked   Status = "blocked"
)

type Step struct {
	ID          string     `json:"id"`
	Status      Status     `json:"status"`
	StartedAt   *time.Time `json:"startedAt,omitempty"`
	CompletedAt *time.Time `json:"completedAt,omitempty"`
	ExitCode    int        `json:"exitCode,omitempty"`
	Evidence    string     `json:"evidence,omitempty"`
	Error       string     `json:"error,omitempty"`
}

type Journal struct {
	APIVersion       string       `json:"apiVersion"`
	OperationID      string       `json:"operationId"`
	CorrelationID    string       `json:"correlationId"`
	CreatedAt        time.Time    `json:"createdAt"`
	UpdatedAt        time.Time    `json:"updatedAt"`
	DesiredStateHash string       `json:"desiredStateHash"`
	Plan             planner.Plan `json:"plan"`
	Status           Status       `json:"status"`
	Steps            []Step       `json:"steps"`
}

type Adapter interface {
	Execute(context.Context, string, ...string) (scripts.Result, error)
	Verify(context.Context, planner.Operation) (string, error)
}

type Engine struct {
	Root    string
	Adapter Adapter
	Now     func() time.Time
}

func New(root string, adapter Adapter) *Engine {
	return &Engine{Root: root, Adapter: adapter, Now: func() time.Time { return time.Now().UTC() }}
}

func (e *Engine) Apply(ctx context.Context, p planner.Plan) (string, error) {
	if len(p.Blockers) != 0 {
		return "", fmt.Errorf("plan is blocked: %s", strings.Join(p.Blockers, "; "))
	}
	if err := validateGraph(p.Operations); err != nil {
		return "", err
	}
	now := e.Now()
	j := Journal{
		APIVersion: "media-stack.journal/v1alpha1", OperationID: p.ID,
		CorrelationID: randomID(), CreatedAt: now, UpdatedAt: now,
		DesiredStateHash: p.DesiredStateHash, Plan: p, Status: Running,
	}
	for _, op := range p.Operations {
		j.Steps = append(j.Steps, Step{ID: op.ID, Status: Pending})
	}
	path := e.journalPath(now, p.ID)
	if err := e.save(path, j); err != nil {
		return "", err
	}
	return path, e.run(ctx, path, &j)
}

func (e *Engine) Resume(ctx context.Context, path string, state config.State) error {
	j, err := LoadJournal(path)
	if err != nil {
		return err
	}
	if err := validateGraph(j.Plan.Operations); err != nil {
		return fmt.Errorf("invalid journal plan: %w", err)
	}
	current, err := desiredHash(state)
	if err != nil {
		return err
	}
	if current != j.DesiredStateHash {
		return errors.New("cannot resume: desired state changed; create a new plan")
	}
	for i := range j.Steps {
		if j.Steps[i].Status != Succeeded {
			continue
		}
		op := operationByID(j.Plan, j.Steps[i].ID)
		evidence, verifyErr := e.Adapter.Verify(ctx, op)
		j.Steps[i].Evidence = secrets.RedactText(evidence)
		if verifyErr != nil {
			j.Steps[i].Status = Pending
			j.Steps[i].Error = "postcondition drifted: " + secrets.RedactText(verifyErr.Error())
			for n := i + 1; n < len(j.Steps); n++ {
				j.Steps[n].Status = Pending
			}
			break
		}
	}
	j.Status = Running
	if err := e.save(path, j); err != nil {
		return err
	}
	return e.run(ctx, path, &j)
}

func (e *Engine) run(ctx context.Context, path string, j *Journal) error {
	for i := range j.Steps {
		step := &j.Steps[i]
		if step.Status == Succeeded {
			continue
		}
		op := operationByID(j.Plan, step.ID)
		if !prerequisitesMet(j, op) {
			step.Status = Blocked
			step.Error = "prerequisite did not succeed"
			j.Status = Blocked
			_ = e.save(path, *j)
			return errors.New(step.Error)
		}
		start := e.Now()
		step.Status, step.StartedAt, step.Error = Running, &start, ""
		if err := e.save(path, *j); err != nil {
			return err
		}
		result, err := e.Adapter.Execute(ctx, op.ScriptCommand, op.ScriptArguments...)
		step.ExitCode = result.ExitCode
		step.Evidence = secrets.RedactText(result.Output)
		if err == nil {
			var evidence string
			evidence, err = e.Adapter.Verify(ctx, op)
			if evidence != "" {
				step.Evidence = secrets.RedactText(evidence)
			}
		}
		finished := e.Now()
		step.CompletedAt = &finished
		if err != nil {
			step.Status = Failed
			step.Error = secrets.RedactText(err.Error())
			j.Status = Failed
			_ = e.save(path, *j)
			return fmt.Errorf("step %s failed: %w", step.ID, err)
		}
		step.Status = Succeeded
		if err := e.save(path, *j); err != nil {
			return err
		}
	}
	j.Status = Succeeded
	return e.save(path, *j)
}

func (e *Engine) journalPath(now time.Time, id string) string {
	name := now.Format("20060102T150405Z") + "-" + id + ".json"
	return filepath.Join(e.Root, ".media-stack", "operations", name)
}

func (e *Engine) save(path string, j Journal) error {
	j.UpdatedAt = e.Now()
	data, err := json.MarshalIndent(j, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	temp := path + ".new"
	if err := os.WriteFile(temp, data, 0o600); err != nil {
		return err
	}
	if runtime.GOOS == "windows" {
		_ = os.Remove(temp)
		return os.WriteFile(path, data, 0o600)
	}
	return os.Rename(temp, path)
}

func LoadJournal(path string) (Journal, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Journal{}, err
	}
	var j Journal
	if err := json.Unmarshal(data, &j); err != nil {
		return Journal{}, err
	}
	if j.APIVersion != "media-stack.journal/v1alpha1" {
		return Journal{}, errors.New("unsupported journal version")
	}
	return j, nil
}

func LatestJournal(root string) (string, error) {
	matches, err := filepath.Glob(filepath.Join(root, ".media-stack", "operations", "*.json"))
	if err != nil {
		return "", err
	}
	if len(matches) == 0 {
		return "", errors.New("no operation journal found")
	}
	sort.Strings(matches)
	return matches[len(matches)-1], nil
}

func validateGraph(ops []planner.Operation) error {
	seen := map[string]bool{}
	for _, op := range ops {
		if op.ID == "" || seen[op.ID] {
			return fmt.Errorf("duplicate or empty operation ID %q", op.ID)
		}
		for _, dependency := range op.Prerequisites {
			if !seen[dependency] {
				return fmt.Errorf("operation %s has missing or unordered prerequisite %s", op.ID, dependency)
			}
		}
		seen[op.ID] = true
	}
	return nil
}

func prerequisitesMet(j *Journal, op planner.Operation) bool {
	for _, required := range op.Prerequisites {
		for _, step := range j.Steps {
			if step.ID == required && step.Status != Succeeded {
				return false
			}
		}
	}
	return true
}

func operationByID(p planner.Plan, id string) planner.Operation {
	for _, op := range p.Operations {
		if op.ID == id {
			return op
		}
	}
	return planner.Operation{}
}

func desiredHash(state config.State) (string, error) {
	data, err := json.Marshal(state)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:]), nil
}

func randomID() string {
	var b [8]byte
	if _, err := rand.Read(b[:]); err != nil {
		return fmt.Sprintf("%d", time.Now().UnixNano())
	}
	return hex.EncodeToString(b[:])
}
