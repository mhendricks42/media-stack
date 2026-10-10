package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

const validState = `apiVersion: media-stack.dev/v1alpha1
kind: MediaStack
metadata:
  name: test
spec:
  platform: linux
  releaseChannel: stable
  storage:
    root: /data
    requireHardlinks: true
  features:
    movies: true
    television: true
    subtitles: true
    liveTv: false
    torrents: true
    usenet: true
  networking:
    bindMode: lan
    remoteAccess: tailscale
    lanSubnet: 192.168.1.0/24
  acceleration:
    mode: intel-quick-sync
  jellyfin:
    serverName: Media Stack
    moonbase:
      enabled: true
      version: 2.4.0.0
      settingsSync: true
      seerrIntegration: true
  secrets:
    provider: interactive-session
    references:
      vpnUsername: openvpn-user-file
      vpnPassword: openvpn-password-file
`

func TestDecodeStrict(t *testing.T) {
	state, err := Decode(strings.NewReader(validState))
	if err != nil {
		t.Fatal(err)
	}
	if state.Spec.Platform != "linux" || !state.Spec.Features.Torrents {
		t.Fatalf("unexpected state: %#v", state)
	}
	_, err = Decode(strings.NewReader(strings.Replace(validState, "releaseChannel:", "releaseChanel:", 1)))
	if err == nil || !strings.Contains(err.Error(), "field releaseChanel not found") {
		t.Fatalf("expected unknown field error, got %v", err)
	}
}

func TestConditionalVPNReferences(t *testing.T) {
	without := strings.ReplaceAll(validState, "      vpnUsername: openvpn-user-file\n      vpnPassword: openvpn-password-file\n", "")
	if _, err := Decode(strings.NewReader(without)); err == nil || !strings.Contains(err.Error(), "vpnUsername") {
		t.Fatalf("expected VPN validation error, got %v", err)
	}
	noTorrents := strings.Replace(without, "    torrents: true", "    torrents: false", 1)
	if _, err := Decode(strings.NewReader(noTorrents)); err != nil {
		t.Fatalf("VPN references should be optional without torrents: %v", err)
	}
}

func TestAdoptEnvDoesNotImportSecrets(t *testing.T) {
	dir := t.TempDir()
	path := dir + "/.env"
	env := "COMPOSE_FILE=docker-compose.yml:compose/linux.yml:compose/secrets.yml\nDATA_ROOT=/srv/media\nLAN_SUBNET=10.0.0.0/24\nVPN_PASS=do-not-import\nTS_AUTHKEY=do-not-import\n"
	if err := os.WriteFile(path, []byte(env), 0o600); err != nil {
		t.Fatal(err)
	}

	adoption, err := AdoptEnv(path)
	if err != nil {
		t.Fatal(err)
	}
	if adoption.WouldMutate || adoption.State.Spec.Platform != "linux" || adoption.State.Spec.Storage.Root != "/srv/media" {
		t.Fatalf("unexpected adoption: %#v", adoption)
	}
	encoded, _ := yaml.Marshal(adoption)
	if strings.Contains(string(encoded), "do-not-import") {
		t.Fatal("adoption leaked secret values")
	}
}

func TestWriteEnvCreatesFromPlatformTemplate(t *testing.T) {
	root := t.TempDir()
	envDir := filepath.Join(root, "env")
	if err := os.Mkdir(envDir, 0o755); err != nil {
		t.Fatal(err)
	}
	template := "# keep this comment\nCOMPOSE_PROJECT_NAME=old\nDATA_ROOT=/old\n"
	if err := os.WriteFile(filepath.Join(envDir, "linux.env.example"), []byte(template), 0o600); err != nil {
		t.Fatal(err)
	}
	state := Defaults()
	state.Spec.Platform = "linux"
	state.Metadata.Name = "Home Media"
	state.Spec.Storage.Root = "/srv/media"
	state.Spec.Secrets.References["vpnUsername"] = "openvpn-user-file"
	state.Spec.Secrets.References["vpnPassword"] = "openvpn-password-file"
	if err := WriteEnv(root, state); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(root, ".env"))
	if err != nil {
		t.Fatal(err)
	}
	text := string(data)
	for _, expected := range []string{"# keep this comment", "COMPOSE_PROJECT_NAME=home-media", "DATA_ROOT=/srv/media", "MOONBASE_VERSION=2.4.0.0"} {
		if !strings.Contains(text, expected) {
			t.Fatalf("generated environment is missing %q:\n%s", expected, text)
		}
	}
}
