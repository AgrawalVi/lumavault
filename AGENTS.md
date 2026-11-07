# LumaVault Agent & Multi-Worktree Development Guide

Always read [`docs/BLUEPRINT.md`](docs/BLUEPRINT.md) for the full architecture and system design.

## 1. Multi-Worktree Ownership Rules

Each AI agent conversation works in an isolated **git worktree** mapped to a specific **Linear Issue** in the **Lumavault (`LUM`)** team.
- **Stay strictly inside your issue's owned paths:** Do not edit files outside the directory/package assigned to your Linear issue unless the issue explicitly covers cross-package integration.
- **Contracts are the boundary:** `proto/lumavault/v1/`, `pkg/metadata/store.go` (`MetadataStore`), and `pkg/chunkstore/store.go` (`ChunkStore`) are shared contracts. Do not break their signatures without updating all callers and generated stubs (`make proto`).

| Linear Project | Owned Paths |
| :--- | :--- |
| **`P-LUM-1` Core Backend, Contracts & Basic Data Layer** | `proto/lumavault/v1/storage.proto`, `buf.*`, `Makefile`, `pkg/metadata/`, `pkg/chunkstore/`, `pkg/gateway/`, `cmd/lumavault/` |
| **`P-LUM-2` Client SDKs (Web/TypeScript & Swift)** | `sdk/web/`, `sdk/swift/`, `Package.swift` |
| **`P-LUM-3` LumaVault Photos** | `apps/photos/` |
| **`P-LUM-4` LumaVault Cinema** | `apps/cinema/` |
| **`P-LUM-5` LumaVault Arcade** | `apps/arcade/` |
| **`P-LUM-6` Distributed Systems Upgrades** | `proto/lumavault/v1/paxos.proto`, `proto/lumavault/v1/chunk.proto`, `pkg/consensus/`, `pkg/chunkserver/` |

## 2. Core Architectural Invariants

1. **Pluggable Backend Stores:** The Gateway (`pkg/gateway/`) talks **only** to the `MetadataStore` (`pkg/metadata/`) and `ChunkStore` (`pkg/chunkstore/`) Go interfaces—never directly to local disk files or Paxos/Chunkserver internals.
2. **Content-Addressed Chunks:** Raw media bytes never enter `MetadataStore` or the Paxos log. All blobs are sliced into `SHA-256` verified chunks in `ChunkStore`.
3. **Dual Client Support (Web + Swift):** The Gateway serves gRPC + Connect-RPC (`StorageService`) plus standard `HTTP 206 Partial Content` byte-range streaming (`GET /v1/stream/{object_id}`) so both `sdk/web` and `sdk/swift` work out of the box.
4. **No Media in Git:** Never commit copyrighted media, ROMs, BIOS files, or `.env` secrets to the repository.

## 3. Standard Commands

- `make proto` — Run `buf lint` and `buf generate` (Go, Swift, and TypeScript/Connect-ES stubs).
- `make test` — Run Go unit/integration tests (`go test -race ./...`) and SDK tests.
- `make build` — Compile `cmd/lumavault`.
