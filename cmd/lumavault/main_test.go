package main

import "testing"

func TestRun(t *testing.T) {
	if err := run(nil); err != nil {
		t.Fatalf("run(nil) returned unexpected error: %v", err)
	}
}
