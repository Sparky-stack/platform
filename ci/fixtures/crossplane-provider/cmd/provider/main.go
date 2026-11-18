// Command provider is a deliberately tiny stand-in for a Crossplane provider
// controller. It exists so koorikla/ci can exercise the provider pipeline
// (generate check, tests, multi-arch controller image, xpkg with embedded
// runtime, push, sign) in a few minutes without crossplane-runtime.
package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/koorikla/ci/fixtures/crossplane-provider/internal/version"
)

// Banner returns the startup line.
func Banner() string {
	return fmt.Sprintf("provider-ci-selftest %s: no controllers registered", version.Version)
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	fmt.Println(Banner())
	<-ctx.Done()
}
