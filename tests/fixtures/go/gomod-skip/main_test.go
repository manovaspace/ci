package main

import "testing"

func TestAdd(t *testing.T) {
	if Add(1, 2) != 3 {
		t.Fatal("Add broken")
	}
}

// TestNeedsDatabase is the shape of the integration tests the release tier must stop hiding:
// without a database it skips, and on tier=release a skip is only allowed when it is listed.
func TestNeedsDatabase(t *testing.T) {
	t.Skip("needs TEST_DATABASE_URL")
}
