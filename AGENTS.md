# LumaVault Agent & Multi-Worktree Development Guide

Always read [`docs/BLUEPRINT.md`](docs/BLUEPRINT.md) for the full architecture and system design.

## 1. Worktrees, Ownership & Linear Docs

Each agent conversation works in its own git worktree, mapped to one Linear issue in the Lumavault (`LUM`) team.

**Linear is the single source of truth for scoping and design docs.** Draft and revise them directly in Linear (`save_document`) under the target project. Do not keep local copies. Only long-lived architecture that the user approves gets copied into `docs/` (for example `docs/BLUEPRINT.md`).

**Doc workflow** (scoping docs, design docs, CUJ specs):
1. Draft the doc in Linear. A scoping doc lists the proposed issues with title, goal, owned paths, dependencies, and acceptance criteria.
2. Run review subagents on it (for example `/ponytail-audit`). Post one `[AGENT]` comment per finding on the doc, quoting the line it refers to and the proposed change.
3. The user reviews the draft and the findings in one pass, leaving inline comments.
4. Address the comments: `list_comments`, reply in-thread to every thread whose latest comment does not start with `[AGENT]`, and update the doc. Repeat until the user approves.
5. For scoping docs, create the issues (`save_issue`) only after approval. Never create issues before that.

**Comment prefix:** every comment or reply an agent posts in Linear starts with `[AGENT] `. User comments have no prefix.

**Stay inside your issue's owned paths** (table below) unless the issue explicitly covers cross-package work.

**Contracts are the boundary:** `proto/lumavault/v1/`, `pkg/metadata/store.go` (`MetadataStore`), and `pkg/chunkstore/store.go` (`ChunkStore`) are shared contracts. Do not break their signatures without updating all callers and running `make proto`. Generated stubs (`gen/go/`, `sdk/web/src/gen/`, `sdk/swift/Sources/LumaVaultSDK/Gen/`) are gitignored.

| Linear Project | Owned Paths |
| :--- | :--- |
| **`P-LUM-1` Core Backend, Contracts & Basic Data Layer** | `proto/lumavault/v1/storage.proto`, `buf.*`, `Makefile`, `docker-compose.yml`, `.gitignore`, `go.*`, `Package.swift`, `sdk/web/package.json`, `sdk/web/tsconfig.json`, `pkg/constants/`, `pkg/metadata/`, `pkg/chunkstore/`, `pkg/gateway/`, `cmd/lumavault/` |
| **`P-LUM-2` Client SDKs (Web/TypeScript & Swift)** | `sdk/web/`, `sdk/swift/`, `Package.swift` |
| **`P-LUM-3` LumaVault Photos** | `apps/photos/` |
| **`P-LUM-4` LumaVault Cinema** | `apps/cinema/` |
| **`P-LUM-5` LumaVault Arcade** | `apps/arcade/` |
| **`P-LUM-6` Distributed Systems Upgrades** | `proto/lumavault/v1/paxos.proto`, `proto/lumavault/v1/chunk.proto`, `pkg/consensus/`, `pkg/chunkserver/` |

## 2. Core Architectural Invariants

1. **Pure Storage Core vs. PostgreSQL Application Layer:**
   - **LumaVault Storage Core (`pkg/gateway/`, `pkg/metadata/`, `pkg/chunkstore/`, `pkg/consensus/`, `pkg/chunkserver/`):** Stores **only** content-addressed object manifests (`ObjectMetadata`: `id`, `namespace`, `filename`, `mime_type`, `size_bytes`, `chunk_size_bytes`, `sha256_digest`, `chunk_hashes`, `thumbnail_chunk_hash`, `created_at`, `updated_at`) and immutable `SHA-256` chunks. The Gateway talks **only** to the `MetadataStore` and `ChunkStore` Go interfaces—never directly to local disk files or Paxos/Chunkserver internals.
   - **PostgreSQL Application Layer (`docker-compose.yml` + `apps/*`):** All application-specific domain metadata, relational queries, and mutable user state (Photo albums, EXIF, Live Photo pairing, trash retention; Cinema TMDB catalog, seasons/episodes, and `playback_position_ms` watch state; Arcade IGDB catalog, consoles, and monotonic save version lineage `v1, v2, v3...`) live in the shared **PostgreSQL** instance referencing `lumavault_object_id`.
2. **Content-Addressed Chunks (`4MB–64MB` over Raw HTTP):** Raw media bytes never enter `MetadataStore`, PostgreSQL, the Paxos log, or Protobuf messages. All blobs are sliced into `SHA-256` verified chunks (`4MB–64MB`, with `chunk_size_bytes` recorded on `ObjectMetadata` for $O(1)$ byte-range seeking) and streamed directly via `PUT /v1/chunks/{sha256}` and `GET /v1/chunks/{sha256}` in `ChunkStore`.
3. **Dual Client Support (Web + Swift via Connect-RPC + Raw HTTP Data Plane):** A single `connectrpc/go` Gateway handler serves Connect, binary gRPC, and gRPC-Web for the Storage Control Plane (`StorageService`: `HasChunks`, `CommitObject`, `GetObject`, `ListObjects`, `UpdateObjectMetadata`, `DeleteObject`), alongside raw HTTP Data Plane endpoints (`PUT /v1/chunks/{sha256}`, `GET /v1/chunks/{sha256}`, and `HTTP 206 Partial Content` `GET /v1/stream/{object_id}`) so both `sdk/web` (`@connectrpc/connect-web`) and `sdk/swift` (`connectrpc/swift`) work out of the box without separate `grpc-go` server boilerplate.
4. **No Media in Git:** Never commit copyrighted media, ROMs, BIOS files, or `.env` secrets to the repository.

## 3. Code Conventions (All Languages)

1. **No Markdown syntax in code comments, ever.** No backticks, `**bold**`, `_italics_`, `#` headings, `[links](...)`, or bullet lists inside `//`, `/** */`, `///`, or `#` comments (Go, TypeScript, Swift, Protobuf, shell). Write identifiers and paths as plain text: `Uploads via PUT /v1/chunks/{sha256} and returns the stored size.` not ``Uploads via `PUT /v1/chunks/{sha256}`...``. Markdown belongs only in `.md` files.
2. **Organization over file count.** Never be afraid of extra files when they buy clearer separation. Each file owns one concern:
   - Public contracts and types (interfaces, option/result types) live apart from implementations (mirror `pkg/chunkstore/store.go` vs `local.go`, `pkg/metadata/store.go` vs `engine.go` vs `local.go`).
   - Constants live in a dedicated constants file or package, never inline in core logic.
   - Validation, URL building, HTTP/body helpers, concurrency primitives, and other utilities live in their own focused modules, not inside the client or service they support.
   - One canonical implementation per helper (one hash validator, one object ID validator, one fetch resolver). Do not duplicate helpers across files with drifting rules.
   - One public entrypoint per package (`index.ts`, the Go package itself). Internal modules do not re-export each other's symbols.
   - Split any file that mixes orchestration with helpers or grows past roughly 300 lines of non-test code.
3. **The user makes design decisions, not the agent.** Whenever work reaches a fork (API shape, error model, wire contract, file/module layout, dependency choice, default values, naming of public symbols, behavior the spec does not pin down), stop and ask a clarifying question with the concrete options and their trade-offs before writing code. Do not pick a default silently and move on, and do not invent wire contracts (HTTP response bodies, headers, error strings) that the Gateway or `proto/` does not already define.

## 4. Standard Commands

- `make proto` — Run `buf lint` and `buf generate` (Go, Swift, and TypeScript/Connect-ES stubs).
- `make lint` — Run `buf lint`, `go vet ./...`, and SDK static checks.
- `make test` — Run Go unit/integration tests (`go test -race ./...`) and SDK tests.
- `make build` — Compile `cmd/lumavault`.

## 5. Ticket Workflow (Branch, PR, Linear)

Linear's GitHub integration handles issue status and PR links automatically when the branch name matches the issue's `gitBranchName`: the PR is linked, the issue moves to In Progress / In Review, and to Done on merge. Do not update status or attach PR links by hand.

1. **Branch first.** Before editing repo files, get the issue's `gitBranchName` (`get_issue`; ask the user which `LUM-XX` if unclear) and run `git fetch origin && git checkout -B <gitBranchName> origin/main`. Work with no issue (tooling, docs, CI) uses `chore/<slug>`, `docs/<slug>`, or `ci/<slug>` instead. `.githooks/` rejects any other branch name and any commit or push to `main` (enable with `git config core.hooksPath .githooks`).
2. **Verify.** Run `make lint` and `make test`.
3. **Open a PR.** `git push -u origin HEAD`, then `gh pr create` with `LUM-XX` in the title. Leave it open for user review and CI. Never push to `main` or merge your own PR.
