package main

import (
	"path/filepath"
	"testing"
)

func TestStateDirectoryAllowsOnlyOneServiceInstance(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "state")
	first, err := lockInstance(directory)
	if err != nil {
		t.Fatal(err)
	}
	defer first.Close()
	if second, err := lockInstance(directory); err == nil {
		second.Close()
		t.Fatal("second instance acquired lock")
	}
	first.Close()
	next, err := lockInstance(directory)
	if err != nil {
		t.Fatal(err)
	}
	next.Close()
}
