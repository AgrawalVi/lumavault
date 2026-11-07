.PHONY: proto build test lint run clean

proto:
	buf lint
	buf generate

build:
	@mkdir -p bin
	go build -o bin/lumavault ./cmd/lumavault

test:
	go test -race ./...

lint:
	buf lint
	go vet ./...

run:
	go run ./cmd/lumavault

clean:
	rm -rf bin/
