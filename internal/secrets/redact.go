package secrets

import (
	"regexp"
	"strings"
)

var sensitiveName = regexp.MustCompile(`(?i)(password|passwd|token|secret|api[_-]?key|auth(?:orization)?|cookie|vpn_(?:user|pass)|openvpn_(?:user|password))`)

func RedactText(text string) string {
	lines := strings.Split(text, "\n")
	for i, line := range lines {
		if key, _, ok := strings.Cut(line, "="); ok && sensitiveName.MatchString(key) {
			lines[i] = key + "=<redacted>"
			continue
		}
		if key, _, ok := strings.Cut(line, ":"); ok && sensitiveName.MatchString(key) {
			lines[i] = key + ": <redacted>"
		}
	}
	return strings.Join(lines, "\n")
}

func RedactMap(values map[string]string) map[string]string {
	out := make(map[string]string, len(values))
	for key, value := range values {
		if sensitiveName.MatchString(key) {
			out[key] = "<redacted>"
		} else {
			out[key] = value
		}
	}
	return out
}
