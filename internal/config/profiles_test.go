package config

import "testing"

func TestProfilesResolveFeatures(t *testing.T) {
	tests := []struct {
		name     string
		torrents bool
		usenet   bool
		remote   string
	}{
		{ProfileRecommended, true, true, "tailscale"},
		{ProfileUsenetOnly, false, true, "tailscale"},
		{ProfileTorrentOnly, true, false, "tailscale"},
		{ProfileLocalOnly, true, true, "none"},
		{ProfileCustom, false, false, "none"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			state, err := FromProfile(test.name, "linux")
			if err != nil {
				t.Fatal(err)
			}
			if state.Spec.Features.Torrents != test.torrents ||
				state.Spec.Features.Usenet != test.usenet ||
				state.Spec.Networking.RemoteAccess != test.remote {
				t.Fatalf("unexpected profile state: %#v", state.Spec)
			}
			if test.torrents && (state.Spec.Secrets.References["vpnUsername"] == "" || state.Spec.Secrets.References["vpnPassword"] == "") {
				t.Fatal("torrent profile is missing VPN secret references")
			}
		})
	}
}

func TestProfileRejectsUnknownName(t *testing.T) {
	if _, err := FromProfile("surprise", "linux"); err == nil {
		t.Fatal("expected unknown profile error")
	}
}
