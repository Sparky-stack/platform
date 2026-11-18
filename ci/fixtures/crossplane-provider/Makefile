.PHONY: generate test build

generate:
	go run ./hack/gencrd package/crds

test:
	go test ./...

build:
	CGO_ENABLED=0 go build -o _output/provider ./cmd/provider
