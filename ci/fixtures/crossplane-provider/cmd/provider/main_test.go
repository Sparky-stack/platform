package main

import (
	"strings"
	"testing"
)

func TestBanner(t *testing.T) {
	if !strings.HasPrefix(Banner(), "provider-ci-selftest dev") {
		t.Fatalf("unexpected banner %q", Banner())
	}
}
