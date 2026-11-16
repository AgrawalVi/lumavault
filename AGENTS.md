# LumaVault Agent & Multi-Worktree Development Guide

Always read [`docs/BLUEPRINT.md`](docs/BLUEPRINT.md) for the full architecture and system design.

## 1. Multi-Worktree Ownership & Linear Scoping Rules

Each AI agent conversation works in an isolated **git worktree** mapped to a specific **Linear Issue** in the **Lumavault (`LUM`)** team.
- **Milestone Scoping & Review Workflow (Never create Linear issues directly):**
  1. **Draft the Linear Issue Plan Artifact & Publish to Linear:** Write the initial proposed Linear issues (titles, descriptions, owned paths, dependencies, and acceptance criteria) to a dedicated Markdown artifact (e.g., `mX_linear_scope.md`) and publish it to Linear (`save_document`) under the target project (`P-LUM-1`–`P-LUM-6`).
  2. **Initial User Review:** The user reviews the initial plan artifact / Linear document and gives the go-ahead for deeper review.
  3. **Subagent Architecture & Quality Audit (Inline `[AGENT]` Comments, One per Finding):** Launch review subagents (e.g., `/improve-codebase-architecture` and `/ponytail-audit`) on the scoping document. **Instead of creating a separate review findings document or a single bundled comment**, post **one individual `[AGENT]` comment per finding** on the Linear scoping document via `save_comment(documentId, body)`, quoting the exact anchored line/deliverable from the plan alongside the issue found and plan update.
  4. **User Verdicts & Plan Updates:** Walk through or apply the review findings on the scoping document, updating both the Linear scoping document (`save_document`) and the local artifact (`mX_linear_scope.md`), and create the issues in Linear (`save_issue`) upon final user approval.
- **Linear Document Review & Threaded Comment Workflow (`[AGENT]` Prefix):**
  1. **Draft Artifacts First, Publish to Linear for Review:** Architecture specs, CUJ documents, and design docs are drafted as local Markdown artifacts first and then published to Linear (`save_document`) under the `LUM` team or target project (`P-LUM-1`–`P-LUM-6`) for inline review.
  2. **User Inline Comments vs. `[AGENT]` Replies:** The user leaves normal inline anchored comments in Linear without any prefix. Whenever an agent posts a comment or reply in Linear via `save_comment`, it **must** prefix the comment body with `[AGENT]` (e.g., `[AGENT] <reply>`) without specifying the agent source.
  3. **Resolving Review Rounds:** When asked to address comments on a Linear document, the agent calls `list_comments(documentId)`, identifies all threads whose latest comment does **not** start with `[AGENT]`, replies in-thread (`save_comment` with `parentId` and `[AGENT]` prefix), updates the Linear document (`save_document`), and syncs approved docs back into the codebase (`docs/`).
- **Stay strictly inside your issue's owned paths:** Do not edit files outside the directory/package assigned to your Linear issue unless the issue explicitly covers cross-package integration.
- **Contracts are the boundary:** `proto/lumavault/v1/`, `pkg/metadata/store.go` (`MetadataStore`), and `pkg/chunkstore/store.go` (`ChunkStore`) are shared contracts. Do not break their signatures without updating all callers and regenerating stubs (`make proto`). Generated Protobuf stubs (`gen/go/`, `sdk/web/src/gen/`, `sdk/swift/Sources/LumaVaultSDK/Gen/`) are gitignored and generated on demand via `make proto`.

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

## 5. Branch, Pull Request & Linear Linking Workflow

Never commit or push directly to `main`, and never keep Antigravity's auto-generated worktree branch slug. Every change follows this lifecycle:
1. **Step 0 — Reset Worktree Branch Before Editing Repo Files:**
   - **Linear issue work (default):** If the user hasn't named a `LUM-XX` issue, ask which Linear issue applies before editing repo files. Call Linear `get_issue` to read its exact `gitBranchName` (e.g., `zvishrut/lum-XX-...`), mark the issue `In Progress`, and reset the worktree branch onto `origin/main`:
     `git fetch origin && git checkout -B <gitBranchName> origin/main`
   - **Non-issue chores only:** For repo tooling, docs, or CI chores without a Linear issue, use `chore/<slug>`, `docs/<slug>`, or `ci/<slug>` (`git fetch origin && git checkout -B chore/<slug> origin/main`).
   - Enforced automatically by `.agents/hooks.json` (blocks `write_file`/`edit_file` on invalid branches) and `.githooks/` (`git config core.hooksPath .githooks`).
2. **Verify Locally:** Run `make lint` and `make test` before pushing.
3. **Open a PR & Link Linear:** Push the branch (`git push -u origin HEAD`), open a GitHub Pull Request via `gh pr create` referencing `LUM-XX` in the title/body, and attach the PR URL to the Linear issue via `save_issue(id, links: [{url, title}])` while keeping the issue `In Progress` until the PR is merged. **Never push directly to `main` or self-merge PRs**—leave every PR open for user review and passing CI checks.
