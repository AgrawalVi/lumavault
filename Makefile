BUF ?= $(shell command -v buf 2>/dev/null || echo $(shell go env GOPATH)/bin/buf)
PROTO_OUTPUTS := \
	gen/go/lumavault/v1/storage.pb.go \
	gen/go/lumavault/v1/lumavaultv1connect/storage.connect.go \
	sdk/web/src/gen/lumavault/v1/storage_pb.ts \
	sdk/swift/Sources/LumaVaultSDK/Gen/lumavault/v1/storage.pb.swift \
	sdk/swift/Sources/LumaVaultSDK/Gen/lumavault/v1/storage.connect.swift
PROTO_STAMP := gen/.proto.stamp
MISSING_PROTO_OUTPUTS := $(strip $(foreach f,$(PROTO_OUTPUTS),$(if $(wildcard $(f)),,$(f))))

.PHONY: proto build test lint run clean force-proto

proto:
	$(BUF) lint
	$(BUF) generate
	@mkdir -p gen && touch $(PROTO_STAMP)

ifneq ($(MISSING_PROTO_OUTPUTS),)
$(PROTO_STAMP): force-proto
endif

$(PROTO_STAMP): proto/lumavault/v1/storage.proto buf.yaml buf.gen.yaml
	$(BUF) generate
	@mkdir -p gen && touch $(PROTO_STAMP)

force-proto:

sdk/web/node_modules: sdk/web/package.json
	npm --prefix sdk/web install --no-package-lock
	@touch sdk/web/node_modules

build: $(PROTO_STAMP) sdk/web/node_modules
	@mkdir -p bin
	go build -o bin/lumavault ./cmd/lumavault
	npm --prefix sdk/web run build
	swift build

test: $(PROTO_STAMP) sdk/web/node_modules
	go test -race ./...
	npm --prefix sdk/web run typecheck
	npm --prefix sdk/web run --if-present test
	swift test

lint: $(PROTO_STAMP) sdk/web/node_modules
	$(BUF) lint
	go vet ./...
	npm --prefix sdk/web run typecheck
	swift build --build-tests

run: $(PROTO_STAMP)
	go run ./cmd/lumavault

clean:
	rm -rf bin/ gen/ sdk/web/src/gen/ sdk/web/dist/ sdk/swift/Sources/LumaVaultSDK/Gen/
