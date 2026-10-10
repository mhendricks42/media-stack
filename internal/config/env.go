package config

import (
	"bufio"
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
)

var projectNameSanitizer = regexp.MustCompile(`[^a-z0-9_-]+`)

// RenderEnv updates only non-secret compatibility values and preserves template comments.
func RenderEnv(template []byte, state State) ([]byte, error) {
	if err := state.Validate(); err != nil {
		return nil, err
	}
	values := map[string]string{
		"COMPOSE_PROJECT_NAME":           sanitizeProjectName(state.Metadata.Name),
		"DATA_ROOT":                      state.Spec.Storage.Root,
		"LAN_SUBNET":                     state.Spec.Networking.LANSubnet,
		"JELLYFIN_SERVER_NAME":           state.Spec.Jellyfin.ServerName,
		"MOONBASE_ENABLED":               fmt.Sprint(state.Spec.Jellyfin.Moonbase.Enabled),
		"MOONBASE_VERSION":               state.Spec.Jellyfin.Moonbase.Version,
		"MOONBASE_SETTINGS_SYNC_ENABLED": fmt.Sprint(state.Spec.Jellyfin.Moonbase.SettingsSync),
		"MOONBASE_SEERR_ENABLED":         fmt.Sprint(state.Spec.Jellyfin.Moonbase.SeerrIntegration),
	}
	if state.Spec.Networking.BindMode == "local" {
		values["BIND_ADDR"] = "127.0.0.1"
	} else {
		values["BIND_ADDR"] = "0.0.0.0"
	}
	if state.Spec.Platform == "windows" {
		if state.Spec.Networking.RemoteAccess == "tailscale" {
			values["COMPOSE_PROFILES"] = "tailscale"
		} else {
			values["COMPOSE_PROFILES"] = ""
		}
	}

	var out bytes.Buffer
	seen := map[string]bool{}
	scanner := bufio.NewScanner(bytes.NewReader(template))
	for scanner.Scan() {
		line := scanner.Text()
		key, _, ok := strings.Cut(line, "=")
		if replacement, replace := values[key]; ok && replace {
			fmt.Fprintf(&out, "%s=%s\n", key, replacement)
			seen[key] = true
		} else {
			out.WriteString(line)
			out.WriteByte('\n')
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	for _, key := range []string{"COMPOSE_PROJECT_NAME", "DATA_ROOT", "BIND_ADDR", "LAN_SUBNET", "JELLYFIN_SERVER_NAME", "MOONBASE_ENABLED", "MOONBASE_VERSION", "MOONBASE_SETTINGS_SYNC_ENABLED", "MOONBASE_SEERR_ENABLED"} {
		if !seen[key] {
			fmt.Fprintf(&out, "%s=%s\n", key, values[key])
		}
	}
	return out.Bytes(), nil
}

func WriteEnv(root string, state State) error {
	path := filepath.Join(root, ".env")
	template, err := os.ReadFile(path)
	if err != nil {
		if !os.IsNotExist(err) {
			return err
		}
		templateName := state.Spec.Platform + ".env.example"
		template, err = os.ReadFile(filepath.Join(root, "env", templateName))
		if err != nil {
			return fmt.Errorf("read %s target template: %w", state.Spec.Platform, err)
		}
	}
	rendered, err := RenderEnv(template, state)
	if err != nil {
		return err
	}
	temp := path + ".new"
	if err := os.WriteFile(temp, rendered, 0o600); err != nil {
		return err
	}
	if runtime.GOOS == "windows" {
		_ = os.Remove(temp)
		return os.WriteFile(path, rendered, 0o600)
	}
	return os.Rename(temp, path)
}

func sanitizeProjectName(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	value = projectNameSanitizer.ReplaceAllString(value, "-")
	value = strings.Trim(value, "-_")
	if value == "" {
		return "media"
	}
	return value
}
