package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/mhendricks42/media-stack/internal/config"
	"github.com/mhendricks42/media-stack/internal/discovery"
	"github.com/mhendricks42/media-stack/internal/planner"
	"github.com/mhendricks42/media-stack/internal/scripts"
	stackstatus "github.com/mhendricks42/media-stack/internal/status"
	"github.com/mhendricks42/media-stack/internal/workflow"
	"gopkg.in/yaml.v3"
)

var version = "dev"

type app struct {
	in     io.Reader
	out    io.Writer
	errOut io.Writer
	cwd    string
}

func main() {
	cwd, err := os.Getwd()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	a := app{in: os.Stdin, out: os.Stdout, errOut: os.Stderr, cwd: cwd}
	if err := a.run(context.Background(), os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "Error:", err)
		os.Exit(1)
	}
}

func (a app) run(ctx context.Context, args []string) error {
	if len(args) == 0 || args[0] == "help" || args[0] == "--help" || args[0] == "-h" {
		a.usage()
		return nil
	}
	if args[0] == "version" || args[0] == "--version" {
		fmt.Fprintf(a.out, "media-stack %s (%s/%s)\n", version, runtime.GOOS, runtime.GOARCH)
		return nil
	}
	root, err := discovery.FindRepositoryRoot(a.cwd)
	if err != nil {
		return err
	}
	switch args[0] {
	case "discover":
		facts, err := discovery.Discover(root)
		if err != nil {
			return err
		}
		return writeJSON(a.out, facts)
	case "plan":
		return a.plan(root, args[1:])
	case "apply":
		return a.apply(ctx, root, args[1:])
	case "resume":
		return a.resume(ctx, root, args[1:])
	case "adopt":
		return a.adopt(root, args[1:])
	case "migrate":
		return a.migrate(root, args[1:])
	case "status":
		return a.status(ctx, root, args[1:])
	case "doctor":
		return a.doctor(ctx, root, args[1:])
	case "logs":
		return a.logs(ctx, root, args[1:])
	case "install":
		return a.install(ctx, root, args[1:])
	case "configure":
		return a.configure(root, args[1:])
	case "repair":
		return a.repair(ctx, root, args[1:])
	case "backup":
		return a.backup(ctx, root, args[1:])
	case "update":
		return a.update(ctx, root, args[1:])
	case "restore":
		return errors.New("restore is unsupported: safe restore requires archive integrity validation and a preview before services can be stopped; use the existing backup archive instructions manually")
	case "rollback":
		return errors.New("rollback is unsupported: application data downgrades are not proven safe; restore a verified backup manually or reconcile forward")
	default:
		return fmt.Errorf("unknown command %q; run media-stack help", args[0])
	}
}

func (a app) configure(root string, args []string) error {
	fs := flag.NewFlagSet("configure", flag.ContinueOnError)
	fs.SetOutput(a.errOut)
	profile := fs.String("profile", "", "recommended, usenet-only, torrent-only, local-only, or custom")
	platform := fs.String("platform", "", "linux or windows")
	name := fs.String("name", "", "deployment name")
	dataRoot := fs.String("data-root", "", "single-filesystem data root")
	lanSubnet := fs.String("lan-subnet", "", "LAN subnet in CIDR notation")
	writePath := fs.String("write", "", "write desired state to this path")
	movies := fs.Bool("movies", false, "custom profile: enable movies")
	television := fs.Bool("television", false, "custom profile: enable television")
	subtitles := fs.Bool("subtitles", false, "custom profile: enable subtitles")
	liveTV := fs.Bool("live-tv", false, "custom profile: enable live TV")
	torrents := fs.Bool("torrents", false, "custom profile: enable torrents")
	usenet := fs.Bool("usenet", false, "custom profile: enable Usenet")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *profile == "" {
		answers, err := a.guidedConfiguration()
		if err != nil {
			return err
		}
		*profile, *platform, *name, *dataRoot = answers.profile, answers.platform, answers.name, answers.dataRoot
	}
	if *platform == "" {
		if runtime.GOOS == "windows" {
			*platform = "windows"
		} else {
			*platform = "linux"
		}
	}
	state, err := config.FromProfile(*profile, *platform)
	if err != nil {
		return err
	}
	if *profile == config.ProfileCustom {
		state.Spec.Features = config.Features{
			Movies: *movies, Television: *television, Subtitles: *subtitles,
			LiveTV: *liveTV, Torrents: *torrents, Usenet: *usenet,
		}
		if *torrents {
			state.Spec.Secrets.References["vpnUsername"] = "openvpn-user-file"
			state.Spec.Secrets.References["vpnPassword"] = "openvpn-password-file"
		}
	}
	if *name != "" {
		state.Metadata.Name = *name
	}
	if *dataRoot != "" {
		state.Spec.Storage.Root = *dataRoot
	}
	if *lanSubnet != "" {
		state.Spec.Networking.LANSubnet = *lanSubnet
	}
	if err := state.Validate(); err != nil {
		return err
	}
	data, err := marshalYAML(state)
	if err != nil {
		return err
	}
	if *writePath == "" {
		_, err = a.out.Write(data)
		return err
	}
	path := *writePath
	if !filepath.IsAbs(path) {
		path = filepath.Join(root, path)
	}
	if err := config.Save(path, state); err != nil {
		return err
	}
	fmt.Fprintln(a.out, "Wrote desired state:", path)
	fmt.Fprintln(a.out, "Review with: media-stack plan --state", path)
	return nil
}

type configurationAnswers struct {
	profile  string
	platform string
	name     string
	dataRoot string
}

func (a app) guidedConfiguration() (configurationAnswers, error) {
	scanner := bufio.NewScanner(a.in)
	ask := func(prompt, fallback string) (string, error) {
		fmt.Fprintf(a.out, "%s [%s]: ", prompt, fallback)
		if !scanner.Scan() {
			if err := scanner.Err(); err != nil {
				return "", err
			}
			return "", errors.New("guided configuration ended before all answers were provided; use --profile and --platform for non-interactive use")
		}
		value := strings.TrimSpace(scanner.Text())
		if value == "" {
			return fallback, nil
		}
		return value, nil
	}
	profile, err := ask("Profile (recommended/usenet-only/torrent-only/local-only/custom)", config.ProfileRecommended)
	if err != nil {
		return configurationAnswers{}, err
	}
	defaultPlatform := "linux"
	if runtime.GOOS == "windows" {
		defaultPlatform = "windows"
	}
	platform, err := ask("Target platform (linux/windows)", defaultPlatform)
	if err != nil {
		return configurationAnswers{}, err
	}
	name, err := ask("Deployment name", "home-media")
	if err != nil {
		return configurationAnswers{}, err
	}
	defaultRoot := "/data"
	if platform == "windows" {
		defaultRoot = `\\wsl$\Ubuntu\home\YOUR_WSL_USER\data`
	}
	dataRoot, err := ask("Data root", defaultRoot)
	return configurationAnswers{profile: profile, platform: platform, name: name, dataRoot: dataRoot}, err
}

func (a app) repair(ctx context.Context, root string, args []string) error {
	if len(args) == 0 || strings.HasPrefix(args[0], "-") {
		return errors.New("usage: media-stack repair <component> [--state media-stack.yaml] [--yes]")
	}
	component := args[0]
	fs := flag.NewFlagSet("repair", flag.ContinueOnError)
	fs.SetOutput(a.errOut)
	statePath := fs.String("state", filepath.Join(root, "media-stack.yaml"), "desired-state YAML")
	yes := fs.Bool("yes", false, "apply the reviewed repair plan")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	state, err := config.Load(*statePath)
	if err != nil {
		return err
	}
	facts, err := discovery.Discover(root)
	if err != nil {
		return err
	}
	p, err := planner.BuildRepair(state, facts, component)
	if err != nil {
		return err
	}
	if err := planner.WriteText(a.out, p); err != nil {
		return err
	}
	if !*yes {
		fmt.Fprintln(a.out, "\nNo changes made. Review the plan, then rerun with --yes.")
		return nil
	}
	journal, err := workflow.New(root, scripts.NewForState(root, state)).Apply(ctx, p)
	if journal != "" {
		fmt.Fprintln(a.out, "Operation journal:", journal)
	}
	return err
}

func (a app) backup(ctx context.Context, root string, args []string) error {
	fs := flag.NewFlagSet("backup", flag.ContinueOnError)
	fs.SetOutput(a.errOut)
	yes := fs.Bool("yes", false, "confirm the service stop and backup")
	if err := fs.Parse(args); err != nil {
		return err
	}
	fmt.Fprintln(a.out, "Backup plan:\n  STOP services\n  ARCHIVE configuration and state\n  START services\n  VERIFY wrapper completion")
	if !*yes {
		return errors.New("backup requires --yes after reviewing the plan")
	}
	return executeCommands(ctx, scripts.New(root), []maintenanceCommand{{name: "backup"}}, a.out)
}

func (a app) update(ctx context.Context, root string, args []string) error {
	fs := flag.NewFlagSet("update", flag.ContinueOnError)
	fs.SetOutput(a.errOut)
	yes := fs.Bool("yes", false, "confirm backup, image pull, restart, and image pruning")
	if err := fs.Parse(args); err != nil {
		return err
	}
	fmt.Fprintln(a.out, "Update plan:\n  1. BACKUP current configuration and state\n  2. PULL images and restart services\n  3. PRUNE unused images through the existing wrapper")
	if !*yes {
		return errors.New("update requires explicit --yes after reviewing the plan")
	}
	return executeCommands(ctx, scripts.New(root), []maintenanceCommand{{name: "backup"}, {name: "pull"}}, a.out)
}

type commandExecutor interface {
	Execute(context.Context, string, ...string) (scripts.Result, error)
}

type maintenanceCommand struct {
	name string
	args []string
}

func executeCommands(ctx context.Context, executor commandExecutor, commands []maintenanceCommand, output io.Writer) error {
	for _, command := range commands {
		result, err := executor.Execute(ctx, command.name, command.args...)
		if result.Output != "" && output != nil {
			fmt.Fprintln(output, result.Output)
		}
		if err != nil {
			return err
		}
	}
	return nil
}

func (a app) plan(root string, args []string) error {
	fs := flag.NewFlagSet("plan", flag.ContinueOnError)
	fs.SetOutput(a.errOut)
	statePath := fs.String("state", filepath.Join(root, "media-stack.yaml"), "desired-state YAML")
	output := fs.String("output", "text", "text or json")
	planOut := fs.String("plan-out", "", "write versioned JSON plan to a file")
	if err := fs.Parse(args); err != nil {
		return err
	}
	state, facts, p, err := buildPlan(root, *statePath)
	_ = state
	_ = facts
	if err != nil {
		return err
	}
	if *planOut != "" {
		if err := planner.Save(*planOut, p); err != nil {
			return err
		}
	}
	switch *output {
	case "text":
		return planner.WriteText(a.out, p)
	case "json":
		return writeJSON(a.out, p)
	default:
		return errors.New("--output must be text or json")
	}
}

func (a app) apply(ctx context.Context, root string, args []string) error {
	fs := flag.NewFlagSet("apply", flag.ContinueOnError)
	fs.SetOutput(a.errOut)
	statePath := fs.String("state", filepath.Join(root, "media-stack.yaml"), "desired-state YAML")
	planPath := fs.String("plan", "", "reviewed plan JSON")
	approved := fs.Bool("non-interactive", false, "confirm the plan was reviewed")
	yes := fs.Bool("yes", false, "confirm the plan was reviewed")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *planPath == "" {
		return errors.New("--plan is required")
	}
	if !*approved && !*yes {
		return errors.New("apply requires --yes or --non-interactive after reviewing the plan")
	}
	state, err := config.Load(*statePath)
	if err != nil {
		return err
	}
	facts, err := discovery.Discover(root)
	if err != nil {
		return err
	}
	p, err := planner.Load(*planPath)
	if err != nil {
		return err
	}
	if err := planner.CheckFresh(p, state, facts); err != nil {
		return err
	}
	engine := workflow.New(root, scripts.NewForState(root, state))
	journal, err := engine.Apply(ctx, p)
	if journal != "" {
		fmt.Fprintln(a.out, "Operation journal:", journal)
	}
	return err
}

func (a app) resume(ctx context.Context, root string, args []string) error {
	fs := flag.NewFlagSet("resume", flag.ContinueOnError)
	fs.SetOutput(a.errOut)
	statePath := fs.String("state", filepath.Join(root, "media-stack.yaml"), "desired-state YAML")
	journalPath := fs.String("journal", "", "operation journal; defaults to latest")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *journalPath == "" {
		var err error
		*journalPath, err = workflow.LatestJournal(root)
		if err != nil {
			return err
		}
	}
	state, err := config.Load(*statePath)
	if err != nil {
		return err
	}
	if err := workflow.New(root, scripts.NewForState(root, state)).Resume(ctx, *journalPath, state); err != nil {
		return err
	}
	fmt.Fprintln(a.out, "Operation completed:", *journalPath)
	return nil
}

func (a app) adopt(root string, args []string) error {
	fs := flag.NewFlagSet("adopt", flag.ContinueOnError)
	fs.SetOutput(a.errOut)
	envPath := fs.String("env", filepath.Join(root, ".env"), "existing environment file")
	writePath := fs.String("write", "", "write inferred desired state after review")
	output := fs.String("output", "yaml", "yaml or json")
	if err := fs.Parse(args); err != nil {
		return err
	}
	adoption, err := config.AdoptEnv(*envPath)
	if err != nil {
		return err
	}
	if *writePath != "" {
		if len(adoption.Unresolved) != 0 {
			return fmt.Errorf("cannot write adoption with unresolved fields: %s", strings.Join(adoption.Unresolved, ", "))
		}
		if err := config.Save(*writePath, adoption.State); err != nil {
			return err
		}
		fmt.Fprintln(a.errOut, "Wrote adopted desired state:", *writePath)
	}
	if *output == "json" {
		return writeJSON(a.out, adoption)
	}
	if *output != "yaml" {
		return errors.New("--output must be yaml or json")
	}
	fmt.Fprintf(a.out, "# Adoption confidence: %s\n# Source: %s\n", adoption.Confidence, adoption.Source)
	if len(adoption.Unresolved) != 0 {
		fmt.Fprintf(a.out, "# Unresolved: %s\n", strings.Join(adoption.Unresolved, ", "))
	}
	data, err := marshalYAML(adoption.State)
	if err == nil {
		_, err = a.out.Write(data)
	}
	return err
}

func (a app) migrate(root string, args []string) error {
	fs := flag.NewFlagSet("migrate", flag.ContinueOnError)
	fs.SetOutput(a.errOut)
	input := fs.String("from", filepath.Join(root, "media-stack.yaml"), "legacy desired state")
	output := fs.String("to", filepath.Join(root, "media-stack.migrated.yaml"), "migrated desired state")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if filepath.Clean(*input) == filepath.Clean(*output) {
		return errors.New("--from and --to must differ to preserve the original")
	}
	if err := config.Migrate(*input, *output); err != nil {
		return err
	}
	fmt.Fprintln(a.out, "Migrated desired state:", *output)
	return nil
}

func (a app) status(ctx context.Context, root string, args []string) error {
	fs := flag.NewFlagSet("status", flag.ContinueOnError)
	fs.SetOutput(a.errOut)
	output := fs.String("output", "text", "text or json")
	if err := fs.Parse(args); err != nil {
		return err
	}
	report := stackstatus.Collect(ctx, root, scripts.New(root))
	if *output == "json" {
		return stackstatus.WriteJSON(a.out, report)
	}
	if *output != "text" {
		return errors.New("--output must be text or json")
	}
	stackstatus.WriteText(a.out, report)
	return nil
}

func (a app) doctor(ctx context.Context, root string, args []string) error {
	fs := flag.NewFlagSet("doctor", flag.ContinueOnError)
	fs.SetOutput(a.errOut)
	output := fs.String("output", "text", "text or json")
	if err := fs.Parse(args); err != nil {
		return err
	}
	report := stackstatus.Collect(ctx, root, scripts.New(root))
	if *output == "json" {
		return stackstatus.WriteJSON(a.out, report)
	}
	stackstatus.WriteText(a.out, report)
	if !report.Healthy {
		return errors.New("doctor found issues; no repairs were performed")
	}
	return nil
}

func (a app) logs(ctx context.Context, root string, args []string) error {
	if len(args) != 1 {
		return errors.New("usage: media-stack logs <component>")
	}
	return scripts.New(root).Logs(ctx, args[0], a.out)
}

func (a app) install(ctx context.Context, root string, args []string) error {
	fs := flag.NewFlagSet("install", flag.ContinueOnError)
	fs.SetOutput(a.errOut)
	statePath := fs.String("state", filepath.Join(root, "media-stack.yaml"), "desired-state YAML")
	apply := fs.Bool("apply", false, "apply immediately after showing the plan")
	yes := fs.Bool("yes", false, "confirm immediate apply")
	if err := fs.Parse(args); err != nil {
		return err
	}
	state, _, p, err := buildPlan(root, *statePath)
	if err != nil {
		return err
	}
	if err := planner.WriteText(a.out, p); err != nil {
		return err
	}
	planDir := filepath.Join(root, ".media-stack", "plans")
	if err := os.MkdirAll(planDir, 0o700); err != nil {
		return err
	}
	planPath := filepath.Join(planDir, p.ID+".json")
	if err := planner.Save(planPath, p); err != nil {
		return err
	}
	fmt.Fprintln(a.out, "\nSaved reviewable plan:", planPath)
	if !*apply {
		fmt.Fprintln(a.out, "Apply with: media-stack apply --state", *statePath, "--plan", planPath, "--yes")
		return nil
	}
	if !*yes {
		return errors.New("install --apply requires --yes after reviewing the displayed plan")
	}
	engine := workflow.New(root, scripts.NewForState(root, state))
	journal, err := engine.Apply(ctx, p)
	fmt.Fprintln(a.out, "Operation journal:", journal)
	return err
}

func buildPlan(root, statePath string) (config.State, discovery.Facts, planner.Plan, error) {
	state, err := config.Load(statePath)
	if err != nil {
		return config.State{}, discovery.Facts{}, planner.Plan{}, err
	}
	facts, err := discovery.Discover(root)
	if err != nil {
		return config.State{}, discovery.Facts{}, planner.Plan{}, err
	}
	p, err := planner.Build(state, facts)
	return state, facts, p, err
}

func writeJSON(w io.Writer, value any) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(value)
}

func marshalYAML(value any) ([]byte, error) {
	return yaml.Marshal(value)
}

func (a app) usage() {
	fmt.Fprintln(a.out, `media-stack - professional deployment coordinator

Usage:
  media-stack discover
  media-stack plan [--state media-stack.yaml] [--output text|json] [--plan-out plan.json]
  media-stack apply --state media-stack.yaml --plan plan.json (--yes|--non-interactive)
  media-stack install --state media-stack.yaml [--apply --yes]
  media-stack configure [--profile PROFILE --platform PLATFORM] [--write media-stack.yaml]
  media-stack resume [--journal path]
  media-stack adopt [--env .env] [--output yaml|json] [--write media-stack.yaml]
  media-stack migrate --from old.yaml --to media-stack.yaml
  media-stack status [--output text|json]
  media-stack doctor [--output text|json]
  media-stack repair <component> [--state media-stack.yaml] [--yes]
  media-stack backup --yes
  media-stack update --yes
  media-stack restore
  media-stack rollback
  media-stack logs <component>
  media-stack version`)
}
