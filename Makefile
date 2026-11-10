BUF ?= $(shell command -v buf 2>/dev/null || echo $(shell go env GOPATH)/bin/buf)
PROTO_STAMPS := \
	gen/go/lumavault/v1/storage.pb.go \
	sdk/web/src/gen/lumavault/v1/storage_pb.ts \
	sdk/swift/Sources/LumaVaultSDK/Gen/lumavault/v1/storage.pb.swift

.PHONY: proto build test lint run clean

proto:
	$(BUF) lint
	$(BUF) generate

gen/go/lumavault/v1/storage.pb.go: proto/lumavault/v1/storage.proto buf.yaml buf.gen.yaml
	$(BUF) generate

sdk/web/src/gen/lumavault/v1/storage_pb.ts: gen/go/lumavault/v1/storage.pb.go
	@test -f $@ || $(BUF) generate

sdk/swift/Sources/LumaVaultSDK/Gen/lumavault/v1/storage.pb.swift: sdk/web/src/gen/lumavault/v1/storage_pb.ts
	@test -f $@ || $(BUF) generate

sdk/web/node_modules: sdk/web/package.json
	npm --prefix sdk/web install --no-package-lock
	@touch sdk/web/node_modules

build: $(PROTO_STAMPS) sdk/web/node_modules
	@mkdir -p bin
	go build -o bin/lumavault ./cmd/lumavault
	npm --prefix sdk/web run build
	swift build

test: $(PROTO_STAMPS) sdk/web/node_modules
	go test -race ./...
	npm --prefix sdk/web run typecheck
	swift build

lint: $(PROTO_STAMPS) sdk/web/node_modules
	$(BUF) lint
	go vet ./...
	npm --prefix sdk/web run typecheck
	swift build

run: $(PROTO_STAMPS)
	go run ./cmd/lumavault

clean:
	rm -rf bin/ gen/ sdk/web/src/gen/ sdk/web/dist/ sdk/swift/Sources/LumaVaultSDK/Gen/
