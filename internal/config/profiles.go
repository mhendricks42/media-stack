package config

import (
	"fmt"
	"sort"
)

const (
	ProfileRecommended = "recommended"
	ProfileUsenetOnly  = "usenet-only"
	ProfileTorrentOnly = "torrent-only"
	ProfileLocalOnly   = "local-only"
	ProfileCustom      = "custom"
)

func ProfileNames() []string {
	names := []string{ProfileRecommended, ProfileUsenetOnly, ProfileTorrentOnly, ProfileLocalOnly, ProfileCustom}
	sort.Strings(names)
	return names
}

func FromProfile(name, platform string) (State, error) {
	state := Defaults()
	state.Spec.Platform = platform
	if platform == "windows" {
		state.Spec.Storage.Root = `\\wsl$\Ubuntu\home\YOUR_WSL_USER\data`
	}
	switch name {
	case ProfileRecommended:
	case ProfileUsenetOnly:
		state.Spec.Features.Torrents = false
	case ProfileTorrentOnly:
		state.Spec.Features.Usenet = false
	case ProfileLocalOnly:
		state.Spec.Networking.RemoteAccess = "none"
	case ProfileCustom:
		state.Spec.Features = Features{}
		state.Spec.Networking.RemoteAccess = "none"
	default:
		return State{}, fmt.Errorf("unknown profile %q; choose one of: %v", name, ProfileNames())
	}
	if state.Spec.Features.Torrents {
		state.Spec.Secrets.References["vpnUsername"] = "openvpn-user-file"
		state.Spec.Secrets.References["vpnPassword"] = "openvpn-password-file"
	}
	if err := state.Validate(); err != nil {
		return State{}, err
	}
	return state, nil
}
