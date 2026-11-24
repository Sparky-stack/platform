// Command app is a golden-path Go HTTP service (Sparky-stack/platform templates/go-service): JSON API, health and
// version endpoints, structured logs, graceful shutdown. Replace the handlers with your own.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

// version is overridden at build time: -ldflags "-X main.version=<git sha>".
var version = "dev"

const shutdownTimeout = 10 * time.Second

// Greeting is the JSON body returned by GET /.
type Greeting struct {
	Message  string `json:"message"`
	Hostname string `json:"hostname"`
	Version  string `json:"version"`
}

// Config is the runtime configuration, read from the environment.
type Config struct {
	Port     string
	Greeting string
	Hostname string
	Version  string
}

func configFromEnv(getenv func(string) string) Config {
	cfg := Config{
		Port:     getenv("PORT"),
		Greeting: getenv("GREETING"),
		Version:  version,
	}
	if cfg.Port == "" {
		cfg.Port = "8080"
	}
	if cfg.Greeting == "" {
		cfg.Greeting = "hello"
	}
	if h, err := os.Hostname(); err == nil {
		cfg.Hostname = h
	}
	return cfg
}

func newHandler(cfg Config) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, Greeting{
			Message:  cfg.Greeting,
			Hostname: cfg.Hostname,
			Version:  cfg.Version,
		})
	})
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("GET /version", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"version": cfg.Version})
	})
	return mux
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// serve runs the HTTP server on ln until ctx is cancelled, then shuts down
// gracefully, letting in-flight requests finish within shutdownTimeout.
func serve(ctx context.Context, ln net.Listener, h http.Handler, log *slog.Logger) error {
	srv := &http.Server{
		Handler:           h,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	errCh := make(chan error, 1)
	go func() {
		log.Info("listening", "addr", ln.Addr().String())
		errCh <- srv.Serve(ln)
	}()

	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
	}

	log.Info("shutting down")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		return err
	}
	if err := <-errCh; err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	cfg := configFromEnv(os.Getenv)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	ln, err := net.Listen("tcp", ":"+cfg.Port)
	if err != nil {
		log.Error("listen failed", "err", err)
		os.Exit(1)
	}
	log.Info("starting", "version", cfg.Version, "greeting", cfg.Greeting)
	if err := serve(ctx, ln, newHandler(cfg), log); err != nil {
		log.Error("server error", "err", err)
		os.Exit(1)
	}
	log.Info("stopped")
}
