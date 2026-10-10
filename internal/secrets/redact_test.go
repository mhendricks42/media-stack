package secrets

import (
	"strings"
	"testing"
)

func TestRedactText(t *testing.T) {
	input := "USER=visible\nVPN_PASS=hunter2\nAuthorization: Bearer abc\napi_key: xyz\nordinary: value"
	got := RedactText(input)
	for _, secret := range []string{"hunter2", "Bearer abc", "xyz"} {
		if strings.Contains(got, secret) {
			t.Fatalf("secret %q remains in %q", secret, got)
		}
	}
	if !strings.Contains(got, "USER=visible") || !strings.Contains(got, "ordinary: value") {
		t.Fatalf("non-secret content changed: %q", got)
	}
}
