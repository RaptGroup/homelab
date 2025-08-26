package main

import (
	"flag"
	"fmt"
	"os"
)

const XDG_CONFIG_HOME = ".config/homelab"

func main() {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		fmt.Println("Error fetching user home directory:", err)
		return
	}
	fmt.Println("Homelab Management CLI (Version 1)", homeDir)
	configPath := flag.String("config", homeDir+"/"+XDG_CONFIG_HOME, "Path to the configuration file")
	flag.Parse()

	_ = *configPath
}
