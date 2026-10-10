package discovery

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

type Facts struct {
	OS               string `json:"os"`
	Architecture     string `json:"architecture"`
	WSL              bool   `json:"wsl"`
	RepositoryRoot   string `json:"repositoryRoot"`
	DockerAvailable  bool   `json:"dockerAvailable"`
	ComposeAvailable bool   `json:"composeAvailable"`
	EnvExists        bool   `json:"envExists"`
	EnvHash          string `json:"envHash,omitempty"`
	EnvPlatform      string `json:"envPlatform,omitempty"`
	ConfigExists     bool   `json:"configExists"`
	SecretsExist     bool   `json:"secretsExist"`
	BackupsExist     bool   `json:"backupsExist"`
	OccupiedPorts    []int  `json:"occupiedPorts,omitempty"`
}

func FindRepositoryRoot(start string) (string, error) {
	absolute, err := filepath.Abs(start)
	if err != nil {
		return "", err
	}
	if info, err := os.Stat(absolute); err == nil && !info.IsDir() {
		absolute = filepath.Dir(absolute)
	}
	for {
		if regular(filepath.Join(absolute, "docker-compose.yml")) &&
			(regular(filepath.Join(absolute, "stack.sh")) || regular(filepath.Join(absolute, "stack.ps1"))) {
			return absolute, nil
		}
		parent := filepath.Dir(absolute)
		if parent == absolute {
			return "", fmt.Errorf("media-stack repository root not found from %s", start)
		}
		absolute = parent
	}
}

func Discover(root string) (Facts, error) {
	root, err := FindRepositoryRoot(root)
	if err != nil {
		return Facts{}, err
	}
	facts := Facts{
		OS: runtime.GOOS, Architecture: runtime.GOARCH,
		WSL: isWSL(), RepositoryRoot: filepath.Clean(root),
		ConfigExists: directory(filepath.Join(root, "config")),
		SecretsExist: directory(filepath.Join(root, "secrets")),
		BackupsExist: directory(filepath.Join(root, "backups")),
	}
	if _, err := exec.LookPath("docker"); err == nil {
		facts.DockerAvailable = true
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, "docker", "compose", "version")
		cmd.Dir = root
		facts.ComposeAvailable = cmd.Run() == nil
	}
	envPath := filepath.Join(root, ".env")
	if data, err := os.ReadFile(envPath); err == nil {
		sum := sha256.Sum256(data)
		facts.EnvExists = true
		facts.EnvHash = hex.EncodeToString(sum[:])
		lower := strings.ToLower(strings.ReplaceAll(string(data), `\`, "/"))
		if strings.Contains(lower, "compose/windows.yml") {
			facts.EnvPlatform = "windows"
		} else if strings.Contains(lower, "compose/linux.yml") {
			facts.EnvPlatform = "linux"
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return Facts{}, err
	}
	for _, port := range []int{5055, 6767, 7878, 8096, 8191, 8989, 9696} {
		conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), 50_000_000)
		if err == nil {
			facts.OccupiedPorts = append(facts.OccupiedPorts, port)
			conn.Close()
		}
	}
	return facts, nil
}

func Hash(f Facts) (string, error) {
	data, err := json.Marshal(f)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:]), nil
}

func regular(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}

func directory(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

func isWSL() bool {
	if os.Getenv("WSL_DISTRO_NAME") != "" {
		return true
	}
	data, err := os.ReadFile("/proc/version")
	return err == nil && strings.Contains(strings.ToLower(string(data)), "microsoft")
}
