package config

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"

	"gopkg.in/yaml.v3"
)

const (
	APIVersion = "media-stack.dev/v1alpha1"
	Kind       = "MediaStack"
)

type State struct {
	APIVersion string   `yaml:"apiVersion" json:"apiVersion"`
	Kind       string   `yaml:"kind" json:"kind"`
	Metadata   Metadata `yaml:"metadata" json:"metadata"`
	Spec       Spec     `yaml:"spec" json:"spec"`
}

type Metadata struct {
	Name string `yaml:"name" json:"name"`
}

type Spec struct {
	Platform       string       `yaml:"platform" json:"platform"`
	ReleaseChannel string       `yaml:"releaseChannel,omitempty" json:"releaseChannel,omitempty"`
	Storage        Storage      `yaml:"storage" json:"storage"`
	Features       Features     `yaml:"features" json:"features"`
	Networking     Networking   `yaml:"networking" json:"networking"`
	Acceleration   Acceleration `yaml:"acceleration,omitempty" json:"acceleration,omitempty"`
	Jellyfin       Jellyfin     `yaml:"jellyfin,omitempty" json:"jellyfin,omitempty"`
	Secrets        Secrets      `yaml:"secrets,omitempty" json:"secrets,omitempty"`
}

type Storage struct {
	Root             string `yaml:"root" json:"root"`
	RequireHardlinks bool   `yaml:"requireHardlinks" json:"requireHardlinks"`
}

type Features struct {
	Movies     bool `yaml:"movies" json:"movies"`
	Television bool `yaml:"television" json:"television"`
	Subtitles  bool `yaml:"subtitles" json:"subtitles"`
	LiveTV     bool `yaml:"liveTv" json:"liveTv"`
	Torrents   bool `yaml:"torrents" json:"torrents"`
	Usenet     bool `yaml:"usenet" json:"usenet"`
}

type Networking struct {
	BindMode     string `yaml:"bindMode" json:"bindMode"`
	RemoteAccess string `yaml:"remoteAccess" json:"remoteAccess"`
	LANSubnet    string `yaml:"lanSubnet,omitempty" json:"lanSubnet,omitempty"`
}

type Acceleration struct {
	Mode string `yaml:"mode,omitempty" json:"mode,omitempty"`
}

type Jellyfin struct {
	ServerName string   `yaml:"serverName,omitempty" json:"serverName,omitempty"`
	Moonbase   Moonbase `yaml:"moonbase,omitempty" json:"moonbase,omitempty"`
}

type Moonbase struct {
	Enabled          bool   `yaml:"enabled" json:"enabled"`
	Version          string `yaml:"version,omitempty" json:"version,omitempty"`
	SettingsSync     bool   `yaml:"settingsSync" json:"settingsSync"`
	SeerrIntegration bool   `yaml:"seerrIntegration" json:"seerrIntegration"`
}

type Secrets struct {
	Provider   string            `yaml:"provider,omitempty" json:"provider,omitempty"`
	References map[string]string `yaml:"references,omitempty" json:"references,omitempty"`
}

func Defaults() State {
	return State{
		APIVersion: APIVersion,
		Kind:       Kind,
		Metadata:   Metadata{Name: "home-media"},
		Spec: Spec{
			ReleaseChannel: "stable",
			Storage:        Storage{Root: "/data", RequireHardlinks: true},
			Features:       Features{Movies: true, Television: true, Subtitles: true, Torrents: true, Usenet: true},
			Networking:     Networking{BindMode: "lan", RemoteAccess: "tailscale", LANSubnet: "192.168.1.0/24"},
			Jellyfin:       Jellyfin{ServerName: "Media Stack", Moonbase: Moonbase{Enabled: true, Version: "2.4.0.0", SettingsSync: true, SeerrIntegration: true}},
			Secrets:        Secrets{Provider: "interactive-session", References: map[string]string{}},
		},
	}
}

func Load(path string) (State, error) {
	f, err := os.Open(path)
	if err != nil {
		return State{}, err
	}
	defer f.Close()
	return Decode(f)
}

func Decode(r io.Reader) (State, error) {
	var state State
	dec := yaml.NewDecoder(r)
	dec.KnownFields(true)
	if err := dec.Decode(&state); err != nil {
		return State{}, fmt.Errorf("decode desired state: %w", err)
	}
	var extra any
	if err := dec.Decode(&extra); !errors.Is(err, io.EOF) {
		if err == nil {
			return State{}, errors.New("decode desired state: multiple YAML documents are not allowed")
		}
		return State{}, fmt.Errorf("decode desired state: %w", err)
	}
	if err := state.Validate(); err != nil {
		return State{}, err
	}
	return state, nil
}

func (s State) Validate() error {
	var problems []string
	if s.APIVersion != APIVersion {
		problems = append(problems, fmt.Sprintf("apiVersion must be %q", APIVersion))
	}
	if s.Kind != Kind {
		problems = append(problems, fmt.Sprintf("kind must be %q", Kind))
	}
	if strings.TrimSpace(s.Metadata.Name) == "" {
		problems = append(problems, "metadata.name is required")
	}
	if s.Spec.Platform != "linux" && s.Spec.Platform != "windows" {
		problems = append(problems, "spec.platform must be linux or windows")
	}
	if strings.TrimSpace(s.Spec.Storage.Root) == "" {
		problems = append(problems, "spec.storage.root is required")
	}
	if s.Spec.ReleaseChannel != "" && s.Spec.ReleaseChannel != "stable" {
		problems = append(problems, "spec.releaseChannel must be stable")
	}
	switch s.Spec.Networking.BindMode {
	case "local", "lan":
	default:
		problems = append(problems, "spec.networking.bindMode must be local or lan")
	}
	switch s.Spec.Networking.RemoteAccess {
	case "none", "tailscale":
	default:
		problems = append(problems, "spec.networking.remoteAccess must be none or tailscale")
	}
	if s.Spec.Features.Torrents {
		for _, key := range []string{"vpnUsername", "vpnPassword"} {
			if strings.TrimSpace(s.Spec.Secrets.References[key]) == "" {
				problems = append(problems, "spec.secrets.references."+key+" is required when torrents are enabled")
			}
		}
	}
	if len(problems) != 0 {
		return errors.New("invalid desired state: " + strings.Join(problems, "; "))
	}
	return nil
}

func Save(path string, s State) error {
	if err := s.Validate(); err != nil {
		return err
	}
	var b bytes.Buffer
	enc := yaml.NewEncoder(&b)
	enc.SetIndent(2)
	if err := enc.Encode(s); err != nil {
		return err
	}
	if err := enc.Close(); err != nil {
		return err
	}
	return os.WriteFile(path, b.Bytes(), 0o600)
}
