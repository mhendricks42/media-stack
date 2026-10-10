package config

import (
	"bytes"
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

// Migrate converts supported legacy desired-state documents to the current schema.
func Migrate(input, output string) error {
	data, err := os.ReadFile(input)
	if err != nil {
		return err
	}
	var raw map[string]any
	if err := yaml.Unmarshal(data, &raw); err != nil {
		return err
	}
	version, _ := raw["apiVersion"].(string)
	switch version {
	case "", "media-stack.dev/v1alpha0", APIVersion:
		raw["apiVersion"] = APIVersion
		raw["kind"] = Kind
	default:
		return fmt.Errorf("unsupported apiVersion %q", version)
	}
	converted, err := yaml.Marshal(raw)
	if err != nil {
		return err
	}
	state, err := DecodeBytes(converted)
	if err != nil {
		return err
	}
	return Save(output, state)
}

func DecodeBytes(data []byte) (State, error) {
	return Decode(bytes.NewReader(data))
}
