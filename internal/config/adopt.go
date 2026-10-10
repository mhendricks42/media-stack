package config

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

type Adoption struct {
	State       State    `json:"state" yaml:"state"`
	Confidence  string   `json:"confidence" yaml:"confidence"`
	Unresolved  []string `json:"unresolved,omitempty" yaml:"unresolved,omitempty"`
	Source      string   `json:"source" yaml:"source"`
	WouldMutate bool     `json:"wouldMutate" yaml:"wouldMutate"`
}

func AdoptEnv(path string) (Adoption, error) {
	f, err := os.Open(path)
	if err != nil {
		return Adoption{}, err
	}
	defer f.Close()
	values, err := ParseEnv(f)
	if err != nil {
		return Adoption{}, err
	}
	s := Defaults()
	s.Spec.Platform = inferPlatform(values["COMPOSE_FILE"])
	s.Spec.Storage.Root = values["DATA_ROOT"]
	s.Spec.Networking.LANSubnet = values["LAN_SUBNET"]
	if values["BIND_ADDR"] == "127.0.0.1" || values["BIND_ADDR"] == "::1" {
		s.Spec.Networking.BindMode = "local"
	}
	if !strings.Contains(values["COMPOSE_PROFILES"], "tailscale") && s.Spec.Platform == "windows" {
		s.Spec.Networking.RemoteAccess = "none"
	}
	if v := values["JELLYFIN_SERVER_NAME"]; v != "" {
		s.Spec.Jellyfin.ServerName = v
	}
	s.Spec.Jellyfin.Moonbase.Enabled = parseBool(values["MOONBASE_ENABLED"], true)
	if v := values["MOONBASE_VERSION"]; v != "" {
		s.Spec.Jellyfin.Moonbase.Version = v
	}
	s.Spec.Jellyfin.Moonbase.SettingsSync = parseBool(values["MOONBASE_SETTINGS_SYNC_ENABLED"], true)
	s.Spec.Jellyfin.Moonbase.SeerrIntegration = parseBool(values["MOONBASE_SEERR_ENABLED"], true)
	s.Spec.Secrets.References["vpnUsername"] = "openvpn-user-file"
	s.Spec.Secrets.References["vpnPassword"] = "openvpn-password-file"

	var unresolved []string
	if s.Spec.Platform == "" {
		unresolved = append(unresolved, "spec.platform")
	}
	if s.Spec.Storage.Root == "" {
		unresolved = append(unresolved, "spec.storage.root")
	}
	confidence := "high"
	if len(unresolved) != 0 {
		confidence = "partial"
	}
	return Adoption{State: s, Confidence: confidence, Unresolved: unresolved, Source: filepath.Clean(path), WouldMutate: false}, nil
}

func ParseEnv(r io.Reader) (map[string]string, error) {
	values := make(map[string]string)
	scanner := bufio.NewScanner(r)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			return nil, fmt.Errorf("invalid environment line %q", line)
		}
		key = strings.TrimSpace(key)
		if key == "" {
			return nil, fmt.Errorf("invalid empty environment key")
		}
		values[key] = strings.Trim(strings.TrimSpace(value), `"'`)
	}
	return values, scanner.Err()
}

func inferPlatform(composeFiles string) string {
	normalized := strings.ToLower(strings.ReplaceAll(composeFiles, `\`, "/"))
	if strings.Contains(normalized, "compose/windows.yml") {
		return "windows"
	}
	if strings.Contains(normalized, "compose/linux.yml") {
		return "linux"
	}
	return ""
}

func parseBool(value string, fallback bool) bool {
	if value == "" {
		return fallback
	}
	return strings.EqualFold(value, "true") || value == "1"
}
