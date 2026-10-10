package status

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"strings"
	"time"

	"github.com/mhendricks42/media-stack/internal/discovery"
	"github.com/mhendricks42/media-stack/internal/scripts"
	"github.com/mhendricks42/media-stack/internal/workflow"
)

type Report struct {
	Facts            discovery.Facts `json:"facts"`
	Runtime          string          `json:"runtime,omitempty"`
	PendingOperation string          `json:"pendingOperation,omitempty"`
	Healthy          bool            `json:"healthy"`
	Issues           []string        `json:"issues,omitempty"`
}

func Collect(ctx context.Context, root string, adapter *scripts.Adapter) Report {
	report := Report{Healthy: true}
	facts, err := discovery.Discover(root)
	if err != nil {
		report.Healthy = false
		report.Issues = append(report.Issues, err.Error())
		return report
	}
	report.Facts = facts
	if !facts.EnvExists {
		report.Issues = append(report.Issues, "no .env target is selected")
	}
	if !facts.DockerAvailable {
		report.Issues = append(report.Issues, "Docker CLI is unavailable")
	} else if !facts.ComposeAvailable {
		report.Issues = append(report.Issues, "Docker Compose v2 is unavailable")
	} else {
		probeCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
		result, runErr := adapter.Execute(probeCtx, "ps")
		cancel()
		report.Runtime = strings.TrimSpace(result.Output)
		if runErr != nil {
			if errors.Is(probeCtx.Err(), context.DeadlineExceeded) {
				report.Issues = append(report.Issues, "Docker Compose status probe timed out after 10 seconds")
			} else {
				report.Issues = append(report.Issues, runErr.Error())
			}
		}
	}
	if path, latestErr := workflow.LatestJournal(root); latestErr == nil {
		if journal, loadErr := workflow.LoadJournal(path); loadErr == nil && journal.Status != workflow.Succeeded {
			report.PendingOperation = filepath.Base(path)
			report.Issues = append(report.Issues, "an operation is "+string(journal.Status)+"; run media-stack resume")
		}
	}
	report.Healthy = len(report.Issues) == 0
	return report
}

func WriteText(w io.Writer, r Report) {
	state := "healthy"
	if !r.Healthy {
		state = "attention required"
	}
	fmt.Fprintf(w, "Media stack: %s\n", state)
	fmt.Fprintf(w, "Host: %s/%s (WSL: %t)\n", r.Facts.OS, r.Facts.Architecture, r.Facts.WSL)
	fmt.Fprintf(w, "Target: %s  Docker: %t  Compose: %t\n", valueOr(r.Facts.EnvPlatform, "not selected"), r.Facts.DockerAvailable, r.Facts.ComposeAvailable)
	if r.Runtime != "" {
		fmt.Fprintln(w, "\nContainers\n"+r.Runtime)
	}
	if len(r.Issues) != 0 {
		fmt.Fprintln(w, "\nIssues")
		for _, issue := range r.Issues {
			fmt.Fprintln(w, "  -", issue)
		}
	}
}

func WriteJSON(w io.Writer, r Report) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(r)
}

func valueOr(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}
