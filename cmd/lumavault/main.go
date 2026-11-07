package main

import (
	"fmt"
	"os"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "lumavault: %v\n", err)
		os.Exit(1)
	}
}

func run(_ []string) error {
	fmt.Println("LumaVault server starting...")
	return nil
}
