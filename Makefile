BUF ?= $(shell command -v buf 2>/dev/null || echo $(shell go env GOPATH)/bin/buf)
PROTO_STAMP := gen/go/lumavault/v1/storage.pb.go

.PHONY: proto build test lint run clean

proto:
	$(BUF) lint
	$(BUF) generate

$(PROTO_STAMP): proto/lumavault/v1/storage.proto buf.yaml buf.gen.yaml
	$(BUF) generate

build: $(PROTO_STAMP)
	@mkdir -p bin
	go build -o bin/lumavault ./cmd/lumavault

test: $(PROTO_STAMP)
	go test -race ./...

lint: $(PROTO_STAMP)
	$(BUF) lint
	go vet ./...

run: $(PROTO_STAMP)
	go run ./cmd/lumavault

clean:
	rm -rf bin/ gen/ sdk/web/src/gen/ sdk/swift/Sources/LumaVaultSDK/Gen/
