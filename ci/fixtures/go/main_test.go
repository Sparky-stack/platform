package main

import "testing"

func TestGreet(t *testing.T) {
	got := Greet("koorikla")
	want := "hello, koorikla (dev)"
	if got != want {
		t.Fatalf("Greet() = %q, want %q", got, want)
	}
}

func TestGreetDefault(t *testing.T) {
	got := Greet("")
	want := "hello, world (dev)"
	if got != want {
		t.Fatalf("Greet() = %q, want %q", got, want)
	}
}
