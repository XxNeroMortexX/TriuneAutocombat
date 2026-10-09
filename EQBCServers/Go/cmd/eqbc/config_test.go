// Created By: NeroMorte
package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestINIAndCLI(t *testing.T) {
	dir := t.TempDir()
	ini := filepath.Join(dir, "EQBCS.ini")
	content := "\ufeff[Other]\r\nPort=9999\r\n[Settings]\r\n; comment\r\nPort=2113\r\nPassword=a=b#c;d\r\nHost=127.0.0.1\r\nVerbose=1\r\nNoTimestamp=true\r\nNoColor=true\r\nUnknown=ignored\r\n"
	if err := os.WriteFile(ini, []byte(content), 0600); err != nil {
		t.Fatal(err)
	}
	executable := func() (string, error) { return filepath.Join(dir, "EQBCS-Go.exe"), nil }
	got, err := loadOptions(nil, executable)
	if err != nil {
		t.Fatal(err)
	}
	if got.Port != 2113 || got.Password != "a=b#c;d" || got.Host != "127.0.0.1" || !got.Verbose || !got.NoTimestamp || !got.NoColor {
		t.Fatalf("INI not applied: %+v", got)
	}
	got, err = loadOptions([]string{"--port", "2114", "--password=", "--host", "0.0.0.0", "--verbose=false", "--no-timestamp=false", "--no-color=false"}, executable)
	if err != nil {
		t.Fatal(err)
	}
	if got.Port != 2114 || got.Password != "" || got.Host != "0.0.0.0" || got.Verbose || got.NoTimestamp || got.NoColor {
		t.Fatalf("CLI did not override: %+v", got)
	}
	got, err = loadOptions([]string{"--no-ini"}, executable)
	if err != nil || got.Port != 2112 || got.Password != "" {
		t.Fatalf("No INI: %+v %v", got, err)
	}
}

func TestConfigurationErrorsAndPaths(t *testing.T) {
	dir := t.TempDir()
	exe := func() (string, error) { return filepath.Join(dir, "EQBCS-Go.exe"), nil }
	got, err := loadOptions(nil, exe)
	if err != nil || got.Port != 2112 {
		t.Fatalf("missing default INI: %+v %v", got, err)
	}
	if _, err := loadOptions([]string{"--ini", filepath.Join(dir, "absent.ini")}, exe); err == nil {
		t.Fatal("missing explicit INI accepted")
	}
	if _, err := loadOptions([]string{"--port", "0"}, exe); err == nil {
		t.Fatal("invalid CLI port accepted")
	}
	ini := filepath.Join(dir, "custom.ini")
	if err := os.WriteFile(ini, []byte("[settings]\nport=70000\n"), 0600); err != nil {
		t.Fatal(err)
	}
	got, err = loadOptions([]string{"--ini", ini}, exe)
	if err != nil || got.Port != 65535 {
		t.Fatalf("clamping/custom path: %+v %v", got, err)
	}
	if err := os.WriteFile(ini, []byte("[Settings]\nPort=bad\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadOptions([]string{"--ini", ini}, exe); err == nil || !strings.Contains(err.Error(), "Port") {
		t.Fatal("invalid INI accepted")
	}
	got, err = loadOptions([]string{"--ini", ini, "--port", "2115"}, exe)
	if err != nil || got.Port != 2115 {
		t.Fatalf("explicit port must override bad INI port: %+v %v", got, err)
	}
}

func TestPacketLogINIAndOverrides(t *testing.T) {
	dir := t.TempDir()
	exe := func() (string, error) { return filepath.Join(dir, "EQBCS-Go.exe"), nil }
	legacy := filepath.Join(dir, "EQBCS.ini")
	specific := filepath.Join(dir, "EQBCS-Go.ini")
	if err := os.WriteFile(legacy, []byte("[Settings]\nPort=2112\nShowInternalPackets=true\n"), 0600); err != nil {
		t.Fatal(err)
	}
	got, err := loadOptions(nil, exe)
	if err != nil || !got.ShowInternalPackets {
		t.Fatalf("legacy settings not retained: %+v %v", got, err)
	}
	if err := os.WriteFile(specific, []byte("[Settings]\nPort=2113\nShowInternalPackets=false\nVerbose=true\n"), 0600); err != nil {
		t.Fatal(err)
	}
	got, err = loadOptions(nil, exe)
	if err != nil || got.Port != 2113 || got.ShowInternalPackets || !got.Verbose {
		t.Fatalf("specific settings: %+v %v", got, err)
	}
	got, err = loadOptions([]string{"--show-internal-packets"}, exe)
	if err != nil || !got.ShowInternalPackets {
		t.Fatalf("CLI debug override: %+v %v", got, err)
	}
	got, err = loadOptions([]string{"--ini", legacy, "--show-internal-packets=false"}, exe)
	if err != nil || got.ShowInternalPackets {
		t.Fatalf("explicit off override: %+v %v", got, err)
	}
}
