package main

import (
	"fmt"
	"net/http"
	"os"
)

var version = "dev"

func Greet(name string) string {
	if name == "" {
		name = "world"
	}
	return fmt.Sprintf("hello, %s (%s)", name, version)
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	if os.Getenv("RUN_SERVER") == "1" {
		_ = http.ListenAndServe(":8080", mux)
	}
	fmt.Println(Greet(os.Getenv("NAME")))
}
