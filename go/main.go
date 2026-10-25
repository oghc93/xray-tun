// cocote — satu binary Go untuk menggantikan komponen Python/Bash yang berat.
//
// Tahap 1 (ini): proxy SSH-WS pengganti /usr/local/bin/ws-dropbear dan
// /usr/local/bin/ws-openssh (sebelumnya Python, satu thread per koneksi).
//
// Pemakaian (argumen sama dengan versi Python):
//
//	cocote ws-dropbear [PORT]            default 2095 -> 127.0.0.1:109
//	cocote ws-openssh  [PORT]            default 2093 -> 127.0.0.1:22
//	cocote ws-dropbear -b 0.0.0.0 -p 2095
package main

import (
	"fmt"
	"os"
	"path/filepath"
)

func main() {
	// Boleh dipanggil lewat symlink bernama ws-dropbear / ws-openssh,
	// atau lewat subcommand: cocote ws-dropbear ...
	name := filepath.Base(os.Args[0])
	args := os.Args[1:]
	if name != "ws-dropbear" && name != "ws-openssh" {
		if len(args) == 0 {
			usage()
			os.Exit(2)
		}
		name, args = args[0], args[1:]
	}

	switch name {
	case "ws-dropbear":
		runWS(wsConfig{
			Name:        "ws-dropbear",
			Title:       "Ws-Dropbear (SSH-WS)",
			DefaultPort: 2095,
			DefaultHost: "127.0.0.1:109",
		}, args)
	case "ws-openssh":
		runWS(wsConfig{
			Name:         "ws-openssh",
			Title:        "Ws-OpenSSH (SSH-WS)",
			DefaultPort:  2093,
			DefaultHost:  "127.0.0.1:22",
			StripPreface: true,
		}, args)
	case "version", "-v", "--version":
		fmt.Println("cocote 1.0.29-trial5-go1")
	default:
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Println("Pemakaian: cocote <ws-dropbear|ws-openssh|version> [PORT | -b ADDR -p PORT]")
}
