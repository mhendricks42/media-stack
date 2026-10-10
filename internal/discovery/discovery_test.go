package discovery

import (
	"os"
	"path/filepath"
	"testing"
)

func TestFindRepositoryRoot(t *testing.T) {
	root := t.TempDir()
	for _, name := range []string{"docker-compose.yml", "stack.sh"} {
		if err := os.WriteFile(filepath.Join(root, name), []byte("test"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	nested := filepath.Join(root, "a", "b")
	if err := os.MkdirAll(nested, 0o700); err != nil {
		t.Fatal(err)
	}
	got, err := FindRepositoryRoot(nested)
	if err != nil {
		t.Fatal(err)
	}
	if got != root {
		t.Fatalf("got %q, want %q", got, root)
	}
}

func TestHashDeterministic(t *testing.T) {
	facts := Facts{OS: "linux", Architecture: "amd64", RepositoryRoot: `C:\repo`}
	a, err := Hash(facts)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := Hash(facts)
	if a != b {
		t.Fatalf("hashes differ: %s %s", a, b)
	}
}
