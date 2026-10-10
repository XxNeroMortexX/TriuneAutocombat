package main

import (
	"fmt"
	"os"

	"github.com/fatih/color"

	"github.com/martinlindhe/eqbc-go"
)

// Edited By: NeroMorte - identify the INI and quiet-packet server build.
const serverVersion = "1.0-NeroMorte.3"

func main() {
	// Edited By: NeroMorte — load server INI settings before explicit CLI overrides.
	args, err := loadOptions(os.Args[1:], os.Executable)
	if err != nil {
		fmt.Fprintln(os.Stderr, "Configuration error:", err)
		os.Exit(1)
	}

	// Edited By: NeroMorte - ship upstream attribution with the executable.
	if args.License {
		fmt.Print(eqbc.License)
		return
	}

	// Edited By: NeroMorte - version queries do not start a listener.
	if args.Version {
		fmt.Println("EQBCS-Go " + serverVersion)
		return
	}

	if args.NoColor {
		color.NoColor = true // disables colorized output
	}

	listenAddr := fmt.Sprintf("%s:%d", args.Host, args.Port)

	server := eqbc.NewServer(eqbc.ServerConfig{
		// Edited By: NeroMorte - internal packet logging stays opt-in, even with verbose enabled.
		ShowInternalPackets: args.ShowInternalPackets,
		// Edited By: NeroMorte - publish this server to the BoxNet Connection tab.
		Discovery:   args.Discovery,
		Verbose:     args.Verbose,
		Password:    args.Password,
		NoTimestamp: args.NoTimestamp,
	})

	// Edited By: NeroMorte - retain a visible version and credits in the server banner.
	banner := " --==> EQBCS-Go " + serverVersion + " LISTENING AT " + listenAddr
	if args.Password != "" {
		// Edited By: NeroMorte — indicate authentication without displaying the configured secret.
		banner += " (password protected)"
	}
	server.Log(banner)

	err = server.Listen(listenAddr)
	if err != nil {
		fmt.Println("ERROR: ", err)
		return
	}
}
