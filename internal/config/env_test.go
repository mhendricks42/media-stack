package config

import (
	"strings"
	"testing"
)

func TestRenderEnvPreservesCommentsAndSecrets(t *testing.T) {
	state := Defaults()
	state.Spec.Platform = "linux"
	state.Spec.Storage.Root = "/srv/data"
	state.Spec.Networking.BindMode = "local"
	state.Spec.Secrets.References["vpnUsername"] = "ref"
	state.Spec.Secrets.References["vpnPassword"] = "ref"
	template := []byte("# keep this\nDATA_ROOT=/data\nBIND_ADDR=0.0.0.0\nVPN_PASS=\n")
	rendered, err := RenderEnv(template, state)
	if err != nil {
		t.Fatal(err)
	}
	got := string(rendered)
	for _, expected := range []string{"# keep this", "DATA_ROOT=/srv/data", "BIND_ADDR=127.0.0.1", "VPN_PASS="} {
		if !strings.Contains(got, expected) {
			t.Fatalf("missing %q in %q", expected, got)
		}
	}
	if strings.Contains(got, "vpnUsername") || strings.Contains(got, "ref") {
		t.Fatalf("secret reference leaked into .env: %q", got)
	}
}
