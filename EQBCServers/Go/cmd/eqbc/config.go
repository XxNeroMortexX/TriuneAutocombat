// Created By: NeroMorte
package main

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/alecthomas/kong"
)

type options struct {
	// Edited By: NeroMorte - discover on the fixed LAN port, advertise actual TCP port.
	Discovery           bool   `help:"Enable IPv4 LAN discovery on UDP 2114." default:"true"`
	License             bool   `help:"Show the upstream MIT license and exit."`
	Version             bool   `help:"Show server build version and exit."`
	Host                string `help:"Listen to host." default:"0.0.0.0"`
	Port                int    `help:"Listen to port." default:"2112"`
	Password            string `help:"Server password." default:""`
	ShowInternalPackets bool   `help:"Display internal Triune transport packets (normally hidden)."`
	Verbose             bool   `short:"v" help:"Be more verbose."`
	NoTimestamp         bool   `help:"Hide timestamps from log."`
	NoColor             bool   `help:"Disable color output."`
	Ini                 string `help:"INI path (default: EQBCS-Go.ini beside the executable, with legacy EQBCS.ini fallback)."`
	NoIni               bool   `help:"Ignore INI settings and use defaults or launch options."`
}

func loadOptions(argv []string, executable func() (string, error)) (options, error) {
	var out options
	parser, err := kong.New(&out, kong.Name("EQBCS-Go"))
	if err != nil {
		return out, err
	}
	ctx, err := parser.Parse(argv)
	if err != nil {
		return out, err
	}
	explicit := map[string]bool{}
	for _, step := range ctx.Path {
		if step.Flag != nil && !step.Resolved {
			explicit[step.Flag.Name] = true
		}
	}
	if out.NoIni && explicit["ini"] {
		return out, errors.New("use either --ini or --no-ini")
	}
	if !out.NoIni && !out.Version && !out.License {
		path := out.Ini
		if path == "" {
			exe, err := executable()
			if err != nil {
				return out, fmt.Errorf("locate executable: %w", err)
			}
			// Edited By: NeroMorte - separate Go settings while preserving existing shared INIs.
			path = filepath.Join(filepath.Dir(exe), "EQBCS-Go.ini")
			if _, err := os.Stat(path); os.IsNotExist(err) {
				legacy := filepath.Join(filepath.Dir(exe), "EQBCS.ini")
				if _, err := os.Stat(legacy); err == nil {
					path = legacy
				}
			}
		}
		values, err := readSettings(path)
		if err != nil && !(os.IsNotExist(err) && !explicit["ini"]) {
			return out, fmt.Errorf("read INI %s: %w", path, err)
		}
		if err == nil {
			if err := applySettings(&out, values, explicit); err != nil {
				return out, fmt.Errorf("INI %s: %w", path, err)
			}
		}
	}
	if out.Port < 1 || out.Port > 65535 {
		return out, errors.New("port must be between 1 and 65535")
	}
	return out, nil
}

// Reads only [Settings]. Unknown keys and other sections remain compatible
// with existing RedGuides files. Password contents after '=' are preserved.
func readSettings(path string) (map[string]string, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	values := map[string]string{}
	scan := bufio.NewScanner(file)
	scan.Buffer(make([]byte, 4096), 1024*1024)
	inSettings := false
	lineNo := 0
	for scan.Scan() {
		lineNo++
		line := strings.TrimSpace(strings.TrimPrefix(scan.Text(), "\ufeff"))
		if line == "" || strings.HasPrefix(line, ";") || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "[") {
			end := strings.IndexByte(line, ']')
			if end < 0 {
				return nil, fmt.Errorf("line %d: invalid section", lineNo)
			}
			inSettings = strings.EqualFold(strings.TrimSpace(line[1:end]), "Settings")
			continue
		}
		if !inSettings {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			return nil, fmt.Errorf("line %d: expected key=value", lineNo)
		}
		values[strings.ToLower(strings.TrimSpace(parts[0]))] = strings.TrimSpace(parts[1])
	}
	return values, scan.Err()
}

func applySettings(out *options, values map[string]string, explicit map[string]bool) error {
	if value, ok := values["port"]; ok && value != "" && !explicit["port"] {
		port, err := strconv.Atoi(value)
		if err != nil {
			return errors.New("Port must be an integer")
		}
		// Match RedGuides' clamping of numeric INI ports.
		if port < 1 {
			port = 1
		}
		if port > 65535 {
			port = 65535
		}
		out.Port = port
	}
	if value, ok := values["password"]; ok && !explicit["password"] {
		out.Password = value
	}
	if value, ok := values["host"]; ok && value != "" && !explicit["host"] {
		out.Host = value
	}
	for _, setting := range []struct {
		key, flag string
		target    *bool
	}{
		{"discovery", "discovery", &out.Discovery},
		{"showinternalpackets", "show-internal-packets", &out.ShowInternalPackets},
		{"verbose", "verbose", &out.Verbose},
		{"notimestamp", "no-timestamp", &out.NoTimestamp},
		{"nocolor", "no-color", &out.NoColor},
	} {
		if value, ok := values[setting.key]; ok && value != "" && !explicit[setting.flag] {
			parsed, err := strconv.ParseBool(value)
			if err != nil {
				return fmt.Errorf("%s must be true/false or 1/0", setting.key)
			}
			*setting.target = parsed
		}
	}
	return nil
}
