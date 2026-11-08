package metadata

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	lumavaultv1 "github.com/AgrawalVi/lumavault/gen/go/lumavault/v1"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/fieldmaskpb"
	"google.golang.org/protobuf/types/known/timestamppb"
)

func testHash(label string) string {
	sum := sha256.Sum256([]byte(label))
	return hex.EncodeToString(sum[:])
}

func TestCommitObject_Validation(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	store, err := NewLocalMetadataStore(t.TempDir())
	if err != nil {
		t.Fatalf("NewLocalMetadataStore: %v", err)
	}

	validDigest := testHash("file-digest")
	chunk0 := testHash("chunk-0")
	chunk1 := testHash("chunk-1")

	tests := []struct {
		name    string
		req     *lumavaultv1.CommitObjectRequest
		wantErr error
	}{
		{
			name:    "nil request",
			req:     nil,
			wantErr: ErrInvalidArgument,
		},
		{
			name: "unspecified namespace",
			req: &lumavaultv1.CommitObjectRequest{
				Namespace:      lumavaultv1.Namespace_NAMESPACE_UNSPECIFIED,
				SizeBytes:      1024,
				ChunkSizeBytes: 4 << 20,
				Sha256Digest:   validDigest,
				ChunkHashes:    []string{chunk0},
			},
			wantErr: ErrInvalidArgument,
		},
		{
			name: "mismatched domain_metadata (cinema on photos)",
			req: &lumavaultv1.CommitObjectRequest{
				Namespace:      lumavaultv1.Namespace_NAMESPACE_PHOTOS,
				SizeBytes:      1024,
				ChunkSizeBytes: 4 << 20,
				Sha256Digest:   validDigest,
				ChunkHashes:    []string{chunk0},
				DomainMetadata: &lumavaultv1.CommitObjectRequest_CinemaMetadata{
					CinemaMetadata: &lumavaultv1.CinemaMetadata{Title: "Wrong Domain"},
				},
			},
			wantErr: ErrInvalidArgument,
		},
		{
			name: "mismatched domain_metadata (photo on cinema)",
			req: &lumavaultv1.CommitObjectRequest{
				Namespace:      lumavaultv1.Namespace_NAMESPACE_CINEMA,
				SizeBytes:      1024,
				ChunkSizeBytes: 4 << 20,
				Sha256Digest:   validDigest,
				ChunkHashes:    []string{chunk0},
				DomainMetadata: &lumavaultv1.CommitObjectRequest_PhotoMetadata{
					PhotoMetadata: &lumavaultv1.PhotoMetadata{CameraMake: "Wrong Domain"},
				},
			},
			wantErr: ErrInvalidArgument,
		},
		{
			name: "mismatched domain_metadata (game on photos)",
			req: &lumavaultv1.CommitObjectRequest{
				Namespace:      lumavaultv1.Namespace_NAMESPACE_PHOTOS,
				SizeBytes:      1024,
				ChunkSizeBytes: 4 << 20,
				Sha256Digest:   validDigest,
				ChunkHashes:    []string{chunk0},
				DomainMetadata: &lumavaultv1.CommitObjectRequest_GameMetadata{
					GameMetadata: &lumavaultv1.GameMetadata{Console: "GBA"},
				},
			},
			wantErr: ErrInvalidArgument,
		},
		{
			name: "invalid sha256_digest",
			req: &lumavaultv1.CommitObjectRequest{
				Namespace:      lumavaultv1.Namespace_NAMESPACE_PHOTOS,
				SizeBytes:      1024,
				ChunkSizeBytes: 4 << 20,
				Sha256Digest:   "INVALID_HASH",
				ChunkHashes:    []string{chunk0},
			},
			wantErr: ErrInvalidArgument,
		},
		{
			name: "invalid chunk_hash element",
			req: &lumavaultv1.CommitObjectRequest{
				Namespace:      lumavaultv1.Namespace_NAMESPACE_PHOTOS,
				SizeBytes:      1024,
				ChunkSizeBytes: 4 << 20,
				Sha256Digest:   validDigest,
				ChunkHashes:    []string{"not-a-sha256"},
			},
			wantErr: ErrInvalidArgument,
		},
		{
			name: "invalid thumbnail_chunk_hash",
			req: &lumavaultv1.CommitObjectRequest{
				Namespace:          lumavaultv1.Namespace_NAMESPACE_PHOTOS,
				SizeBytes:          1024,
				ChunkSizeBytes:     4 << 20,
				Sha256Digest:       validDigest,
				ChunkHashes:        []string{chunk0},
				ThumbnailChunkHash: "UPPERCASE_OR_SHORT",
			},
			wantErr: ErrInvalidArgument,
		},
		{
			name: "chunk_size_bytes == 0 when size_bytes > 0",
			req: &lumavaultv1.CommitObjectRequest{
				Namespace:      lumavaultv1.Namespace_NAMESPACE_PHOTOS,
				SizeBytes:      1024,
				ChunkSizeBytes: 0,
				Sha256Digest:   validDigest,
				ChunkHashes:    []string{chunk0},
			},
			wantErr: ErrInvalidArgument,
		},
		{
			name: "chunk_size_bytes exceeds 64 MiB",
			req: &lumavaultv1.CommitObjectRequest{
				Namespace:      lumavaultv1.Namespace_NAMESPACE_PHOTOS,
				SizeBytes:      1024,
				ChunkSizeBytes: MaxChunkSizeBytes + 1,
				Sha256Digest:   validDigest,
				ChunkHashes:    []string{chunk0},
			},
			wantErr: ErrInvalidArgument,
		},
		{
			name: "chunk count mismatch (expects 2 chunks, got 1)",
			req: &lumavaultv1.CommitObjectRequest{
				Namespace:      lumavaultv1.Namespace_NAMESPACE_PHOTOS,
				SizeBytes:      (4 << 20) + 1,
				ChunkSizeBytes: 4 << 20,
				Sha256Digest:   validDigest,
				ChunkHashes:    []string{chunk0},
			},
			wantErr: ErrInvalidArgument,
		},
		{
			name: "zero size_bytes with non-empty chunk_hashes",
			req: &lumavaultv1.CommitObjectRequest{
				Namespace:      lumavaultv1.Namespace_NAMESPACE_PHOTOS,
				SizeBytes:      0,
				ChunkSizeBytes: 4 << 20,
				Sha256Digest:   validDigest,
				ChunkHashes:    []string{chunk0},
			},
			wantErr: ErrInvalidArgument,
		},
		{
			name: "game save referencing non-existent parent ROM",
			req: &lumavaultv1.CommitObjectRequest{
				Namespace:      lumavaultv1.Namespace_NAMESPACE_GAMES,
				SizeBytes:      256,
				ChunkSizeBytes: 4 << 20,
				Sha256Digest:   validDigest,
				ChunkHashes:    []string{chunk0},
				DomainMetadata: &lumavaultv1.CommitObjectRequest_GameMetadata{
					GameMetadata: &lumavaultv1.GameMetadata{
						Console:           "GBA",
						ParentRomObjectId: "missing-rom-id",
					},
				},
			},
			wantErr: ErrObjectNotFound,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			_, _, err := store.CommitObject(ctx, tc.req)
			if !errors.Is(err, tc.wantErr) {
				t.Fatalf("got err=%v, want %v", err, tc.wantErr)
			}
		})
	}

	// Verify exact boundary chunk math: size_bytes == 2 * chunk_size_bytes requires 2 chunks.
	obj, dedup, err := store.CommitObject(ctx, &lumavaultv1.CommitObjectRequest{
		Namespace:      lumavaultv1.Namespace_NAMESPACE_PHOTOS,
		Filename:       "exact.jpg",
		SizeBytes:      8 << 20,
		ChunkSizeBytes: 4 << 20,
		Sha256Digest:   validDigest,
		ChunkHashes:    []string{chunk0, chunk1},
	})
	if err != nil || dedup || obj.Id == "" {
		t.Fatalf("expected valid boundary CommitObject to succeed, got obj=%v dedup=%v err=%v", obj, dedup, err)
	}
}

func TestCommitObject_DeduplicationChunkRefsAndPersistenceReload(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	rootDir := t.TempDir()
	store, err := NewLocalMetadataStore(rootDir)
	if err != nil {
		t.Fatalf("NewLocalMetadataStore: %v", err)
	}

	sharedChunk := testHash("shared-chunk")
	uniqueChunk := testHash("unique-chunk")
	thumbChunk := testHash("thumb-chunk")
	photoDigest := testHash("photo-1")

	req := &lumavaultv1.CommitObjectRequest{
		Namespace:          lumavaultv1.Namespace_NAMESPACE_PHOTOS,
		Filename:           "IMG_0001.HEIC",
		MimeType:           "image/heic",
		SizeBytes:          4 << 20,
		ChunkSizeBytes:     4 << 20,
		Sha256Digest:       photoDigest,
		ChunkHashes:        []string{sharedChunk},
		ThumbnailChunkHash: thumbChunk,
		DomainMetadata: &lumavaultv1.CommitObjectRequest_PhotoMetadata{
			PhotoMetadata: &lumavaultv1.PhotoMetadata{
				CameraMake: "Apple",
				AlbumIds:   []string{"favorites"},
			},
		},
	}

	first, dedup, err := store.CommitObject(ctx, req)
	if err != nil || dedup {
		t.Fatalf("first CommitObject: dedup=%v err=%v", dedup, err)
	}

	// Second commit with same (NAMESPACE_PHOTOS, sha256_digest) must deduplicate.
	second, dedup, err := store.CommitObject(ctx, req)
	if err != nil || !dedup || second.Id != first.Id {
		t.Fatalf("expected second commit deduplicated=true with ID %q, got dedup=%v id=%q err=%v", first.Id, dedup, second.Id, err)
	}

	// Reload LocalMetadataStore on the same directory and verify deduplication and chunkRefs survive restart.
	store, err = NewLocalMetadataStore(rootDir)
	if err != nil {
		t.Fatalf("NewLocalMetadataStore reload: %v", err)
	}
	third, dedup, err := store.CommitObject(ctx, req)
	if err != nil || !dedup || third.Id != first.Id {
		t.Fatalf("expected post-reload commit deduplicated=true with ID %q, got dedup=%v id=%q err=%v", first.Id, dedup, third.Id, err)
	}

	// Commit a Cinema object referencing sharedChunk and uniqueChunk.
	cinemaReq := &lumavaultv1.CommitObjectRequest{
		Namespace:      lumavaultv1.Namespace_NAMESPACE_CINEMA,
		Filename:       "clip.mp4",
		MimeType:       "video/mp4",
		SizeBytes:      8 << 20,
		ChunkSizeBytes: 4 << 20,
		Sha256Digest:   testHash("cinema-1"),
		ChunkHashes:    []string{sharedChunk, uniqueChunk},
	}
	cinema1, dedup, err := store.CommitObject(ctx, cinemaReq)
	if err != nil || dedup {
		t.Fatalf("cinema1 CommitObject: dedup=%v err=%v", dedup, err)
	}
	cinema2, dedup, err := store.CommitObject(ctx, cinemaReq)
	if err != nil || dedup || cinema2.Id == cinema1.Id {
		t.Fatalf("expected cinema2 to create a distinct object without deduplication, got dedup=%v id=%s", dedup, cinema2.Id)
	}
	if err := store.DeleteObject(ctx, cinema2.Id); err != nil {
		t.Fatalf("DeleteObject cinema2: %v", err)
	}

	// Check chunk references while both first (photo) and cinema1 exist.
	for _, h := range []string{sharedChunk, uniqueChunk, thumbChunk} {
		ref, err := store.IsChunkReferenced(ctx, h)
		if err != nil || !ref {
			t.Fatalf("expected chunk %s to be referenced, got ref=%v err=%v", h, ref, err)
		}
	}

	// Delete the photo object: thumbChunk becomes unreferenced, but sharedChunk remains referenced by cinema1.
	if err := store.DeleteObject(ctx, first.Id); err != nil {
		t.Fatalf("DeleteObject first: %v", err)
	}
	if ref, err := store.IsChunkReferenced(ctx, thumbChunk); err != nil || ref {
		t.Fatalf("expected thumbChunk to be unreferenced after photo deletion, got ref=%v err=%v", ref, err)
	}
	if ref, err := store.IsChunkReferenced(ctx, sharedChunk); err != nil || !ref {
		t.Fatalf("expected sharedChunk to remain referenced by cinema1, got ref=%v err=%v", ref, err)
	}

	// Re-committing the photo after deletion must create a new object (deduplicated=false).
	recommitted, dedup, err := store.CommitObject(ctx, req)
	if err != nil || dedup || recommitted.Id == first.Id {
		t.Fatalf("expected recommit after delete to create new object, got dedup=%v id=%s err=%v", dedup, recommitted.Id, err)
	}
	if err := store.DeleteObject(ctx, recommitted.Id); err != nil {
		t.Fatalf("DeleteObject recommitted: %v", err)
	}
	if err := store.DeleteObject(ctx, cinema1.Id); err != nil {
		t.Fatalf("DeleteObject cinema1: %v", err)
	}

	// Now sharedChunk and uniqueChunk must both be unreferenced.
	for _, h := range []string{sharedChunk, uniqueChunk} {
		if ref, err := store.IsChunkReferenced(ctx, h); err != nil || ref {
			t.Fatalf("expected chunk %s to be unreferenced after all objects deleted, got ref=%v err=%v", h, ref, err)
		}
	}
}

func TestMonotonicGameSaveVersioning_ConcurrentAndPersistent(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	rootDir := t.TempDir()

	store, err := NewLocalMetadataStore(rootDir)
	if err != nil {
		t.Fatalf("NewLocalMetadataStore: %v", err)
	}

	romChunk := testHash("emerald-rom-chunk")
	romReq := &lumavaultv1.CommitObjectRequest{
		Namespace:      lumavaultv1.Namespace_NAMESPACE_GAMES,
		Filename:       "emerald.gba",
		SizeBytes:      16 << 20,
		ChunkSizeBytes: 16 << 20,
		Sha256Digest:   testHash("emerald-rom"),
		ChunkHashes:    []string{romChunk},
		DomainMetadata: &lumavaultv1.CommitObjectRequest_GameMetadata{
			GameMetadata: &lumavaultv1.GameMetadata{
				Console: "GBA",
				IgdbId:  1234,
			},
		},
	}

	romObj, dedup, err := store.CommitObject(ctx, romReq)
	if err != nil || dedup {
		t.Fatalf("CommitObject ROM: dedup=%v err=%v", dedup, err)
	}
	// Verify ROM deduplication on (NAMESPACE_GAMES, sha256_digest).
	romDedup, dedup, err := store.CommitObject(ctx, romReq)
	if err != nil || !dedup || romDedup.Id != romObj.Id {
		t.Fatalf("expected ROM commit to deduplicate, got dedup=%v id=%q err=%v", dedup, romDedup.Id, err)
	}

	// Concurrent save commits against the same parent ROM.
	const numConcurrentSaves = 10
	var wg sync.WaitGroup
	versions := make(chan uint32, numConcurrentSaves)
	saveIDs := make(chan string, numConcurrentSaves)

	for i := 0; i < numConcurrentSaves; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			saveChunk := testHash(fmt.Sprintf("save-chunk-%d", idx))
			saveObj, dedup, err := store.CommitObject(ctx, &lumavaultv1.CommitObjectRequest{
				Namespace:      lumavaultv1.Namespace_NAMESPACE_GAMES,
				Filename:       "emerald.sav",
				SizeBytes:      65536,
				ChunkSizeBytes: 4 << 20,
				Sha256Digest:   testHash("identical-save-payload"),
				ChunkHashes:    []string{saveChunk},
				DomainMetadata: &lumavaultv1.CommitObjectRequest_GameMetadata{
					GameMetadata: &lumavaultv1.GameMetadata{
						Console:           "GBA",
						ParentRomObjectId: romObj.Id,
						SaveKind:          lumavaultv1.SaveKind_SAVE_KIND_BATTERY_SAV,
					},
				},
			})
			if err != nil {
				t.Errorf("concurrent save %d failed: %v", idx, err)
				return
			}
			if dedup {
				t.Errorf("concurrent save %d unexpectedly deduplicated", idx)
				return
			}
			versions <- saveObj.GetGameMetadata().GetSaveVersion()
			saveIDs <- saveObj.Id
		}(i)
	}
	wg.Wait()
	close(versions)
	close(saveIDs)

	seen := make(map[uint32]bool)
	for v := range versions {
		if v < 1 || v > numConcurrentSaves || seen[v] {
			t.Fatalf("unexpected or duplicate save_version %d (seen=%v)", v, seen)
		}
		seen[v] = true
	}

	// Verify a save cannot be used as the parent_rom_object_id of another save.
	var anySaveID string
	for id := range saveIDs {
		anySaveID = id
		break
	}
	_, _, err = store.CommitObject(ctx, &lumavaultv1.CommitObjectRequest{
		Namespace:      lumavaultv1.Namespace_NAMESPACE_GAMES,
		Filename:       "nested.sav",
		SizeBytes:      1024,
		ChunkSizeBytes: 4 << 20,
		Sha256Digest:   testHash("nested-save"),
		ChunkHashes:    []string{romChunk},
		DomainMetadata: &lumavaultv1.CommitObjectRequest_GameMetadata{
			GameMetadata: &lumavaultv1.GameMetadata{
				Console:           "GBA",
				ParentRomObjectId: anySaveID,
			},
		},
	})
	if !errors.Is(err, ErrInvalidArgument) {
		t.Fatalf("expected ErrInvalidArgument when parent_rom_object_id points to a save, got %v", err)
	}

	// Paginate saves for the ROM using page_size=4 to exercise sortBySaveVersion cursor pagination.
	savePage1, err := store.ListObjects(ctx, &lumavaultv1.ListObjectsRequest{
		Namespace:         lumavaultv1.Namespace_NAMESPACE_GAMES,
		ParentRomObjectId: romObj.Id,
		PageSize:          4,
	})
	if err != nil || len(savePage1.Objects) != 4 || savePage1.NextPageToken == "" {
		t.Fatalf("savePage1: len=%d token=%q err=%v", len(savePage1.Objects), savePage1.NextPageToken, err)
	}
	if savePage1.Objects[0].GetGameMetadata().GetSaveVersion() != 10 ||
		savePage1.Objects[3].GetGameMetadata().GetSaveVersion() != 7 {
		t.Fatalf("unexpected savePage1 versions: first=%d last=%d",
			savePage1.Objects[0].GetGameMetadata().GetSaveVersion(),
			savePage1.Objects[3].GetGameMetadata().GetSaveVersion())
	}

	// Passing a save-version page_token to a non-ParentRomObjectId query must return ErrInvalidArgument.
	if _, err := store.ListObjects(ctx, &lumavaultv1.ListObjectsRequest{
		Namespace: lumavaultv1.Namespace_NAMESPACE_GAMES,
		PageToken: savePage1.NextPageToken,
	}); !errors.Is(err, ErrInvalidArgument) {
		t.Fatalf("expected ErrInvalidArgument when reusing save-version page_token on timestamp query, got %v", err)
	}

	savePage2, err := store.ListObjects(ctx, &lumavaultv1.ListObjectsRequest{
		Namespace:         lumavaultv1.Namespace_NAMESPACE_GAMES,
		ParentRomObjectId: romObj.Id,
		PageSize:          4,
		PageToken:         savePage1.NextPageToken,
	})
	if err != nil || len(savePage2.Objects) != 4 || savePage2.NextPageToken == "" {
		t.Fatalf("savePage2: len=%d token=%q err=%v", len(savePage2.Objects), savePage2.NextPageToken, err)
	}

	savePage3, err := store.ListObjects(ctx, &lumavaultv1.ListObjectsRequest{
		Namespace:         lumavaultv1.Namespace_NAMESPACE_GAMES,
		ParentRomObjectId: romObj.Id,
		PageSize:          4,
		PageToken:         savePage2.NextPageToken,
	})
	if err != nil || len(savePage3.Objects) != 2 || savePage3.NextPageToken != "" {
		t.Fatalf("savePage3: len=%d token=%q err=%v", len(savePage3.Objects), savePage3.NextPageToken, err)
	}

	// Delete the highest save (v10), reload store from disk, and verify next save gets v11 (monotonic!).
	highestSaveID := savePage1.Objects[0].Id
	if err := store.DeleteObject(ctx, highestSaveID); err != nil {
		t.Fatalf("DeleteObject highestSaveID: %v", err)
	}

	reloaded, err := NewLocalMetadataStore(rootDir)
	if err != nil {
		t.Fatalf("NewLocalMetadataStore reload: %v", err)
	}

	nextSave, _, err := reloaded.CommitObject(ctx, &lumavaultv1.CommitObjectRequest{
		Namespace:      lumavaultv1.Namespace_NAMESPACE_GAMES,
		Filename:       "emerald.sav",
		SizeBytes:      65536,
		ChunkSizeBytes: 4 << 20,
		Sha256Digest:   testHash("post-reload-save"),
		ChunkHashes:    []string{romChunk},
		DomainMetadata: &lumavaultv1.CommitObjectRequest_GameMetadata{
			GameMetadata: &lumavaultv1.GameMetadata{
				Console:           "GBA",
				ParentRomObjectId: romObj.Id,
				SaveKind:          lumavaultv1.SaveKind_SAVE_KIND_BATTERY_SAV,
			},
		},
	})
	if err != nil {
		t.Fatalf("CommitObject post-reload save: %v", err)
	}
	wantVersion := uint32(numConcurrentSaves + 1)
	if nextSave.GetGameMetadata().GetSaveVersion() != wantVersion {
		t.Fatalf("expected monotonic save_version=%d after deleting v%d and reloading, got %d",
			wantVersion, numConcurrentSaves, nextSave.GetGameMetadata().GetSaveVersion())
	}
}

func TestListObjects_FilteringAndPagination(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	store, err := NewLocalMetadataStore(t.TempDir())
	if err != nil {
		t.Fatalf("NewLocalMetadataStore: %v", err)
	}

	chunk := testHash("photo-chunk")
	for i := 0; i < 5; i++ {
		albums := []string{"all"}
		if i%2 == 0 {
			albums = append(albums, "even")
		}
		_, _, err := store.CommitObject(ctx, &lumavaultv1.CommitObjectRequest{
			Namespace:      lumavaultv1.Namespace_NAMESPACE_PHOTOS,
			Filename:       fmt.Sprintf("photo_%d.jpg", i),
			SizeBytes:      1024,
			ChunkSizeBytes: 4 << 20,
			Sha256Digest:   testHash(fmt.Sprintf("photo-digest-%d", i)),
			ChunkHashes:    []string{chunk},
			DomainMetadata: &lumavaultv1.CommitObjectRequest_PhotoMetadata{
				PhotoMetadata: &lumavaultv1.PhotoMetadata{
					AlbumIds: albums,
				},
			},
		})
		if err != nil {
			t.Fatalf("CommitObject %d: %v", i, err)
		}
	}

	// Commit two ROMs on different consoles ("GBA" and "SNES") to test Console filtering.
	for _, console := range []string{"GBA", "SNES"} {
		_, _, err := store.CommitObject(ctx, &lumavaultv1.CommitObjectRequest{
			Namespace:      lumavaultv1.Namespace_NAMESPACE_GAMES,
			Filename:       console + ".rom",
			SizeBytes:      1024,
			ChunkSizeBytes: 4 << 20,
			Sha256Digest:   testHash("rom-" + console),
			ChunkHashes:    []string{chunk},
			DomainMetadata: &lumavaultv1.CommitObjectRequest_GameMetadata{
				GameMetadata: &lumavaultv1.GameMetadata{Console: console},
			},
		})
		if err != nil {
			t.Fatalf("CommitObject ROM %s: %v", console, err)
		}
	}

	snesResp, err := store.ListObjects(ctx, &lumavaultv1.ListObjectsRequest{
		Namespace: lumavaultv1.Namespace_NAMESPACE_GAMES,
		Console:   "SNES",
		PageSize:  999, // clamped to MaxPageSize
	})
	if err != nil || len(snesResp.Objects) != 1 || snesResp.Objects[0].GetGameMetadata().GetConsole() != "SNES" {
		t.Fatalf("expected 1 SNES object, got %+v (err=%v)", snesResp, err)
	}

	// Filter by album_id = "even" (should match 3 photos: 0, 2, 4).
	evenResp, err := store.ListObjects(ctx, &lumavaultv1.ListObjectsRequest{
		Namespace: lumavaultv1.Namespace_NAMESPACE_PHOTOS,
		AlbumId:   "even",
	})
	if err != nil || len(evenResp.Objects) != 3 {
		t.Fatalf("expected 3 objects in 'even' album, got %v (err=%v)", len(evenResp.Objects), err)
	}

	// Paginate all 5 photos with page_size = 2, and delete the boundary item after page 1
	// to verify cursor pagination remains stable even when boundary items are deleted.
	page1, err := store.ListObjects(ctx, &lumavaultv1.ListObjectsRequest{
		Namespace: lumavaultv1.Namespace_NAMESPACE_PHOTOS,
		PageSize:  2,
	})
	if err != nil || len(page1.Objects) != 2 || page1.NextPageToken == "" {
		t.Fatalf("page1: len=%d token=%q err=%v", len(page1.Objects), page1.NextPageToken, err)
	}

	// Delete the 2nd item of page1 (the cursor boundary object) before fetching page2.
	if err := store.DeleteObject(ctx, page1.Objects[1].Id); err != nil {
		t.Fatalf("DeleteObject boundary item: %v", err)
	}

	page2, err := store.ListObjects(ctx, &lumavaultv1.ListObjectsRequest{
		Namespace: lumavaultv1.Namespace_NAMESPACE_PHOTOS,
		PageSize:  2,
		PageToken: page1.NextPageToken,
	})
	if err != nil || len(page2.Objects) != 2 || page2.NextPageToken == "" {
		t.Fatalf("page2: len=%d token=%q err=%v", len(page2.Objects), page2.NextPageToken, err)
	}

	page3, err := store.ListObjects(ctx, &lumavaultv1.ListObjectsRequest{
		Namespace: lumavaultv1.Namespace_NAMESPACE_PHOTOS,
		PageSize:  2,
		PageToken: page2.NextPageToken,
	})
	if err != nil || len(page3.Objects) != 1 || page3.NextPageToken != "" {
		t.Fatalf("page3: len=%d token=%q err=%v", len(page3.Objects), page3.NextPageToken, err)
	}

	// Verify invalid ListObjects arguments.
	if _, err := store.ListObjects(ctx, nil); !errors.Is(err, ErrInvalidArgument) {
		t.Fatalf("expected ErrInvalidArgument for nil request, got %v", err)
	}
	if _, err := store.ListObjects(ctx, &lumavaultv1.ListObjectsRequest{
		Namespace: lumavaultv1.Namespace_NAMESPACE_UNSPECIFIED,
	}); !errors.Is(err, ErrInvalidArgument) {
		t.Fatalf("expected ErrInvalidArgument for unspecified namespace, got %v", err)
	}
	if _, err := store.ListObjects(ctx, &lumavaultv1.ListObjectsRequest{
		Namespace: lumavaultv1.Namespace_NAMESPACE_PHOTOS,
		PageSize:  -1,
	}); !errors.Is(err, ErrInvalidArgument) {
		t.Fatalf("expected ErrInvalidArgument for negative page_size, got %v", err)
	}
	if _, err := store.ListObjects(ctx, &lumavaultv1.ListObjectsRequest{
		Namespace: lumavaultv1.Namespace_NAMESPACE_PHOTOS,
		PageToken: "!!!not-base64!!!",
	}); !errors.Is(err, ErrInvalidArgument) {
		t.Fatalf("expected ErrInvalidArgument for invalid page_token, got %v", err)
	}
}

func TestUpdateObjectMetadata_AllDomainFieldMasks(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	store, err := NewLocalMetadataStore(t.TempDir())
	if err != nil {
		t.Fatalf("NewLocalMetadataStore: %v", err)
	}

	chunk := testHash("chunk-a")
	oldThumb := testHash("thumb-old")
	newThumb := testHash("thumb-new")

	// 1. Photo object initially committed without PhotoMetadata to test lazy initialization + all photo_metadata.* paths.
	photo, _, err := store.CommitObject(ctx, &lumavaultv1.CommitObjectRequest{
		Namespace:          lumavaultv1.Namespace_NAMESPACE_PHOTOS,
		Filename:           "before.jpg",
		MimeType:           "image/jpeg",
		SizeBytes:          2048,
		ChunkSizeBytes:     4 << 20,
		Sha256Digest:       testHash("photo-update-test"),
		ChunkHashes:        []string{chunk},
		ThumbnailChunkHash: oldThumb,
	})
	if err != nil {
		t.Fatalf("CommitObject photo: %v", err)
	}

	takenAt := timestamppb.New(time.Date(2026, 5, 1, 12, 0, 0, 0, time.UTC))
	updatedPhoto, err := store.UpdateObjectMetadata(ctx, &lumavaultv1.UpdateObjectMetadataRequest{
		Object: &lumavaultv1.ObjectMetadata{
			Id:                 photo.Id,
			Filename:           "after.heic",
			MimeType:           "image/heic",
			ThumbnailChunkHash: newThumb,
			DomainMetadata: &lumavaultv1.ObjectMetadata_PhotoMetadata{
				PhotoMetadata: &lumavaultv1.PhotoMetadata{
					LivePhotoPairId: "pair-123",
					TakenAt:         takenAt,
					Latitude:        37.7749,
					Longitude:       -122.4194,
					Width:           4032,
					Height:          3024,
					CameraMake:      "Apple",
					CameraModel:     "iPhone 16 Pro",
					AlbumIds:        []string{"vacation", "highlights"},
				},
			},
		},
		UpdateMask: &fieldmaskpb.FieldMask{
			Paths: []string{
				"filename",
				"mime_type",
				"thumbnail_chunk_hash",
				"photo_metadata.live_photo_pair_id",
				"photo_metadata.taken_at",
				"photo_metadata.latitude",
				"photo_metadata.longitude",
				"photo_metadata.width",
				"photo_metadata.height",
				"photo_metadata.camera_make",
				"photo_metadata.camera_model",
				"photo_metadata.album_ids",
			},
		},
	})
	if err != nil {
		t.Fatalf("UpdateObjectMetadata photo fields: %v", err)
	}
	pm := updatedPhoto.GetPhotoMetadata()
	if updatedPhoto.Filename != "after.heic" || updatedPhoto.MimeType != "image/heic" ||
		pm.GetCameraMake() != "Apple" || pm.GetCameraModel() != "iPhone 16 Pro" ||
		pm.GetWidth() != 4032 || pm.GetHeight() != 3024 ||
		pm.GetLatitude() != 37.7749 || pm.GetLongitude() != -122.4194 ||
		pm.GetLivePhotoPairId() != "pair-123" || len(pm.GetAlbumIds()) != 2 {
		t.Fatalf("unexpected updatedPhoto: %+v", updatedPhoto)
	}

	// Verify chunk refcounts adjusted from oldThumb to newThumb.
	if ref, err := store.IsChunkReferenced(ctx, oldThumb); err != nil || ref {
		t.Fatalf("expected oldThumb unreferenced, got ref=%v err=%v", ref, err)
	}
	if ref, err := store.IsChunkReferenced(ctx, newThumb); err != nil || !ref {
		t.Fatalf("expected newThumb referenced, got ref=%v err=%v", ref, err)
	}

	// Whole-submessage replacement & nil clearing for photo_metadata.
	updatedPhoto, err = store.UpdateObjectMetadata(ctx, &lumavaultv1.UpdateObjectMetadataRequest{
		Object:     &lumavaultv1.ObjectMetadata{Id: photo.Id},
		UpdateMask: &fieldmaskpb.FieldMask{Paths: []string{"photo_metadata"}},
	})
	if err != nil || updatedPhoto.GetPhotoMetadata() != nil {
		t.Fatalf("expected photo_metadata to be cleared to nil, got %+v (err=%v)", updatedPhoto.GetPhotoMetadata(), err)
	}
	updatedPhoto, err = store.UpdateObjectMetadata(ctx, &lumavaultv1.UpdateObjectMetadataRequest{
		Object: &lumavaultv1.ObjectMetadata{
			Id: photo.Id,
			DomainMetadata: &lumavaultv1.ObjectMetadata_PhotoMetadata{
				PhotoMetadata: &lumavaultv1.PhotoMetadata{CameraMake: "Sony"},
			},
		},
		UpdateMask: &fieldmaskpb.FieldMask{Paths: []string{"photo_metadata"}},
	})
	if err != nil || updatedPhoto.GetPhotoMetadata().GetCameraMake() != "Sony" {
		t.Fatalf("expected whole photo_metadata replacement, got %+v (err=%v)", updatedPhoto.GetPhotoMetadata(), err)
	}

	// 2. Cinema object: test lazy initialization + all cinema_metadata.* paths + whole replacement/clearing.
	cinema, _, err := store.CommitObject(ctx, &lumavaultv1.CommitObjectRequest{
		Namespace:      lumavaultv1.Namespace_NAMESPACE_CINEMA,
		Filename:       "movie.mkv",
		SizeBytes:      4096,
		ChunkSizeBytes: 4 << 20,
		Sha256Digest:   testHash("cinema-update-test"),
		ChunkHashes:    []string{chunk},
	})
	if err != nil {
		t.Fatalf("CommitObject cinema: %v", err)
	}

	updatedCinema, err := store.UpdateObjectMetadata(ctx, &lumavaultv1.UpdateObjectMetadataRequest{
		Object: &lumavaultv1.ObjectMetadata{
			Id: cinema.Id,
			DomainMetadata: &lumavaultv1.ObjectMetadata_CinemaMetadata{
				CinemaMetadata: &lumavaultv1.CinemaMetadata{
					PlaybackPositionMs: 120000,
					DurationMs:         7200000,
					TmdbId:             603,
					Title:              "The Matrix",
					Overview:           "Sci-fi classic",
					PosterUrl:          "https://image.tmdb.org/poster.jpg",
					BackdropUrl:        "https://image.tmdb.org/backdrop.jpg",
					ReleaseYear:        1999,
					SeasonNumber:       1,
					EpisodeNumber:      2,
				},
			},
		},
		UpdateMask: &fieldmaskpb.FieldMask{
			Paths: []string{
				"cinema_metadata.playback_position_ms",
				"cinema_metadata.duration_ms",
				"cinema_metadata.tmdb_id",
				"cinema_metadata.title",
				"cinema_metadata.overview",
				"cinema_metadata.poster_url",
				"cinema_metadata.backdrop_url",
				"cinema_metadata.release_year",
				"cinema_metadata.season_number",
				"cinema_metadata.episode_number",
			},
		},
	})
	if err != nil {
		t.Fatalf("UpdateObjectMetadata cinema fields: %v", err)
	}
	cm := updatedCinema.GetCinemaMetadata()
	if cm.GetTitle() != "The Matrix" || cm.GetTmdbId() != 603 || cm.GetPlaybackPositionMs() != 120000 ||
		cm.GetDurationMs() != 7200000 || cm.GetReleaseYear() != 1999 ||
		cm.GetSeasonNumber() != 1 || cm.GetEpisodeNumber() != 2 ||
		cm.GetPosterUrl() == "" || cm.GetBackdropUrl() == "" || cm.GetOverview() == "" {
		t.Fatalf("unexpected updatedCinema: %+v", cm)
	}

	// Whole-submessage clear & replace for cinema_metadata.
	updatedCinema, err = store.UpdateObjectMetadata(ctx, &lumavaultv1.UpdateObjectMetadataRequest{
		Object:     &lumavaultv1.ObjectMetadata{Id: cinema.Id},
		UpdateMask: &fieldmaskpb.FieldMask{Paths: []string{"cinema_metadata"}},
	})
	if err != nil || updatedCinema.GetCinemaMetadata() != nil {
		t.Fatalf("expected cinema_metadata cleared to nil, got %+v (err=%v)", updatedCinema.GetCinemaMetadata(), err)
	}
	updatedCinema, err = store.UpdateObjectMetadata(ctx, &lumavaultv1.UpdateObjectMetadataRequest{
		Object: &lumavaultv1.ObjectMetadata{
			Id: cinema.Id,
			DomainMetadata: &lumavaultv1.ObjectMetadata_CinemaMetadata{
				CinemaMetadata: &lumavaultv1.CinemaMetadata{Title: "Reloaded"},
			},
		},
		UpdateMask: &fieldmaskpb.FieldMask{Paths: []string{"cinema_metadata"}},
	})
	if err != nil || updatedCinema.GetCinemaMetadata().GetTitle() != "Reloaded" {
		t.Fatalf("expected whole cinema_metadata replacement, got %+v (err=%v)", updatedCinema.GetCinemaMetadata(), err)
	}

	// 3. Game object (ROM + Save): test lazy initialization + all game_metadata.* paths + immutability checks.
	game, _, err := store.CommitObject(ctx, &lumavaultv1.CommitObjectRequest{
		Namespace:      lumavaultv1.Namespace_NAMESPACE_GAMES,
		Filename:       "zelda.gba",
		SizeBytes:      4096,
		ChunkSizeBytes: 4 << 20,
		Sha256Digest:   testHash("game-update-test"),
		ChunkHashes:    []string{chunk},
	})
	if err != nil {
		t.Fatalf("CommitObject game: %v", err)
	}

	updatedGame, err := store.UpdateObjectMetadata(ctx, &lumavaultv1.UpdateObjectMetadataRequest{
		Object: &lumavaultv1.ObjectMetadata{
			Id: game.Id,
			DomainMetadata: &lumavaultv1.ObjectMetadata_GameMetadata{
				GameMetadata: &lumavaultv1.GameMetadata{
					Console:   "GBA",
					IgdbId:    999,
					BoxArtUrl: "https://images.igdb.com/zelda.jpg",
					SaveKind:  lumavaultv1.SaveKind_SAVE_KIND_BATTERY_SAV,
				},
			},
		},
		UpdateMask: &fieldmaskpb.FieldMask{
			Paths: []string{
				"game_metadata.console",
				"game_metadata.igdb_id",
				"game_metadata.box_art_url",
				"game_metadata.save_kind",
			},
		},
	})
	if err != nil {
		t.Fatalf("UpdateObjectMetadata game fields: %v", err)
	}
	gm := updatedGame.GetGameMetadata()
	if gm.GetConsole() != "GBA" || gm.GetIgdbId() != 999 || gm.GetBoxArtUrl() == "" ||
		gm.GetSaveKind() != lumavaultv1.SaveKind_SAVE_KIND_BATTERY_SAV {
		t.Fatalf("unexpected updatedGame: %+v", gm)
	}

	// Reject mutating immutable game_metadata.parent_rom_object_id or game_metadata.save_version via whole submessage or direct path.
	for _, badMask := range []*lumavaultv1.UpdateObjectMetadataRequest{
		{
			Object:     &lumavaultv1.ObjectMetadata{Id: game.Id},
			UpdateMask: &fieldmaskpb.FieldMask{Paths: []string{"game_metadata.save_version"}},
		},
		{
			Object:     &lumavaultv1.ObjectMetadata{Id: game.Id},
			UpdateMask: &fieldmaskpb.FieldMask{Paths: []string{"game_metadata.parent_rom_object_id"}},
		},
		{
			Object: &lumavaultv1.ObjectMetadata{
				Id: game.Id,
				DomainMetadata: &lumavaultv1.ObjectMetadata_GameMetadata{
					GameMetadata: &lumavaultv1.GameMetadata{ParentRomObjectId: "other-rom"},
				},
			},
			UpdateMask: &fieldmaskpb.FieldMask{Paths: []string{"game_metadata"}},
		},
		{
			Object: &lumavaultv1.ObjectMetadata{
				Id: game.Id,
				DomainMetadata: &lumavaultv1.ObjectMetadata_GameMetadata{
					GameMetadata: &lumavaultv1.GameMetadata{SaveVersion: 5},
				},
			},
			UpdateMask: &fieldmaskpb.FieldMask{Paths: []string{"game_metadata"}},
		},
	} {
		if _, err := store.UpdateObjectMetadata(ctx, badMask); !errors.Is(err, ErrInvalidArgument) {
			t.Fatalf("expected ErrInvalidArgument for immutable game_metadata mutation, got %v", err)
		}
	}

	// Clearing game_metadata to nil on a ROM sets DomainMetadata to nil.
	updatedGame, err = store.UpdateObjectMetadata(ctx, &lumavaultv1.UpdateObjectMetadataRequest{
		Object:     &lumavaultv1.ObjectMetadata{Id: game.Id},
		UpdateMask: &fieldmaskpb.FieldMask{Paths: []string{"game_metadata"}},
	})
	if err != nil || updatedGame.GetGameMetadata() != nil {
		t.Fatalf("expected ROM game_metadata cleared to nil, got %+v (err=%v)", updatedGame.GetGameMetadata(), err)
	}
}

func TestEngine_RestoreDeterminismAndDeepCloneIsolation(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	store, err := NewLocalMetadataStore(t.TempDir())
	if err != nil {
		t.Fatalf("NewLocalMetadataStore: %v", err)
	}

	chunk := testHash("clone-chunk")
	req := &lumavaultv1.CommitObjectRequest{
		Namespace:      lumavaultv1.Namespace_NAMESPACE_PHOTOS,
		Filename:       "immutable.jpg",
		SizeBytes:      1024,
		ChunkSizeBytes: 4 << 20,
		Sha256Digest:   testHash("clone-digest"),
		ChunkHashes:    []string{chunk},
		DomainMetadata: &lumavaultv1.CommitObjectRequest_PhotoMetadata{
			PhotoMetadata: &lumavaultv1.PhotoMetadata{
				AlbumIds: []string{"album-1"},
			},
		},
	}

	committed, _, err := store.CommitObject(ctx, req)
	if err != nil {
		t.Fatalf("CommitObject: %v", err)
	}

	// Mutate request and returned object slices in caller memory; verify store state is unaffected.
	req.ChunkHashes[0] = "corrupted-in-caller"
	committed.Filename = "corrupted-filename"
	committed.ChunkHashes[0] = "corrupted-in-response"
	committed.GetPhotoMetadata().AlbumIds[0] = "corrupted-album"

	fetched, err := store.GetObject(ctx, committed.Id)
	if err != nil {
		t.Fatalf("GetObject: %v", err)
	}
	if fetched.Filename != "immutable.jpg" || fetched.ChunkHashes[0] != chunk ||
		fetched.GetPhotoMetadata().GetAlbumIds()[0] != "album-1" {
		t.Fatalf("caller mutation leaked into store state: %+v", fetched)
	}

	// Test Engine.Restore validation (rejecting nil, empty ID, and duplicate IDs without wiping existing state)
	// and deterministic DeleteObject fallback when two restored objects share (namespace, sha256_digest).
	eng := NewEngine()
	sharedDigest := testHash("dup-photo-digest")
	t1 := timestamppb.New(time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC))
	objA := &lumavaultv1.ObjectMetadata{
		Id:             "obj-a",
		Namespace:      lumavaultv1.Namespace_NAMESPACE_PHOTOS,
		SizeBytes:      100,
		ChunkSizeBytes: 4 << 20,
		Sha256Digest:   sharedDigest,
		ChunkHashes:    []string{chunk},
		CreatedAt:      t1,
	}
	objB := &lumavaultv1.ObjectMetadata{
		Id:             "obj-b",
		Namespace:      lumavaultv1.Namespace_NAMESPACE_PHOTOS,
		SizeBytes:      100,
		ChunkSizeBytes: 4 << 20,
		Sha256Digest:   sharedDigest,
		ChunkHashes:    []string{chunk},
		CreatedAt:      t1, // identical timestamp to test Id ASC tie-breaking
	}
	objC := &lumavaultv1.ObjectMetadata{
		Id:             "obj-c",
		Namespace:      lumavaultv1.Namespace_NAMESPACE_PHOTOS,
		SizeBytes:      100,
		ChunkSizeBytes: 4 << 20,
		Sha256Digest:   sharedDigest,
		ChunkHashes:    []string{chunk},
		CreatedAt:      t1,
	}

	if err := eng.Restore([]*lumavaultv1.ObjectMetadata{objC, objA, objB}, nil); err != nil {
		t.Fatalf("Engine.Restore: %v", err)
	}

	// Failed Restore (duplicate ID) must not wipe existing state in eng.
	if err := eng.Restore([]*lumavaultv1.ObjectMetadata{objA, objA}, nil); !errors.Is(err, ErrInvalidArgument) {
		t.Fatalf("expected ErrInvalidArgument on duplicate ID in Restore, got %v", err)
	}
	if err := eng.Restore([]*lumavaultv1.ObjectMetadata{nil}, nil); !errors.Is(err, ErrInvalidArgument) {
		t.Fatalf("expected ErrInvalidArgument on nil object in Restore, got %v", err)
	}

	// Because Restore sorts by (CreatedAt ASC, Id ASC), "obj-a" must be the active deduplication target.
	// Deleting "obj-a" must deterministically promote "obj-b" (not "obj-c").
	if err := eng.DeleteObject("obj-a"); err != nil {
		t.Fatalf("eng.DeleteObject(obj-a): %v", err)
	}
	dedupObj, dedup, err := eng.CommitObject(&lumavaultv1.CommitObjectRequest{
		Namespace:      lumavaultv1.Namespace_NAMESPACE_PHOTOS,
		SizeBytes:      100,
		ChunkSizeBytes: 4 << 20,
		Sha256Digest:   sharedDigest,
		ChunkHashes:    []string{chunk},
	}, "new-id", time.Now())
	if err != nil || !dedup || dedupObj.Id != "obj-b" {
		t.Fatalf("expected deterministic fallback to 'obj-b', got dedup=%v id=%q err=%v", dedup, dedupObj.Id, err)
	}
}

func TestLocalMetadataStore_DiskErrorsContextAndCleanup(t *testing.T) {
	t.Parallel()

	if _, err := NewLocalMetadataStore(""); err == nil {
		t.Fatalf("expected error for empty rootDir")
	}

	rootDir := t.TempDir()
	// Pre-populate an orphaned file in tmp/ and verify NewLocalMetadataStore removes it.
	tmpDir := filepath.Join(rootDir, "tmp")
	if err := os.MkdirAll(tmpDir, 0o755); err != nil {
		t.Fatalf("MkdirAll tmp: %v", err)
	}
	orphanPath := filepath.Join(tmpDir, "meta-orphan")
	if err := os.WriteFile(orphanPath, []byte("orphan"), 0o644); err != nil {
		t.Fatalf("WriteFile orphan: %v", err)
	}

	store, err := NewLocalMetadataStore(rootDir)
	if err != nil {
		t.Fatalf("NewLocalMetadataStore: %v", err)
	}
	if _, err := os.Stat(orphanPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("expected orphan temp file to be cleaned up on startup, got err=%v", err)
	}

	// Verify cancelled context handling on all 6 MetadataStore methods.
	cancelledCtx, cancel := context.WithCancel(context.Background())
	cancel()

	if _, _, err := store.CommitObject(cancelledCtx, &lumavaultv1.CommitObjectRequest{}); !errors.Is(err, context.Canceled) {
		t.Fatalf("expected context.Canceled on CommitObject, got %v", err)
	}
	if _, err := store.GetObject(cancelledCtx, "id"); !errors.Is(err, context.Canceled) {
		t.Fatalf("expected context.Canceled on GetObject, got %v", err)
	}
	if _, err := store.ListObjects(cancelledCtx, &lumavaultv1.ListObjectsRequest{}); !errors.Is(err, context.Canceled) {
		t.Fatalf("expected context.Canceled on ListObjects, got %v", err)
	}
	if _, err := store.UpdateObjectMetadata(cancelledCtx, &lumavaultv1.UpdateObjectMetadataRequest{}); !errors.Is(err, context.Canceled) {
		t.Fatalf("expected context.Canceled on UpdateObjectMetadata, got %v", err)
	}
	if err := store.DeleteObject(cancelledCtx, "id"); !errors.Is(err, context.Canceled) {
		t.Fatalf("expected context.Canceled on DeleteObject, got %v", err)
	}
	if _, err := store.IsChunkReferenced(cancelledCtx, testHash("x")); !errors.Is(err, context.Canceled) {
		t.Fatalf("expected context.Canceled on IsChunkReferenced, got %v", err)
	}

	// Verify unsafe object IDs and invalid hash errors.
	ctx := context.Background()
	if _, err := store.GetObject(ctx, "../unsafe"); !errors.Is(err, ErrInvalidArgument) {
		t.Fatalf("expected ErrInvalidArgument on unsafe GetObject ID, got %v", err)
	}
	if err := store.DeleteObject(ctx, "../unsafe"); !errors.Is(err, ErrInvalidArgument) {
		t.Fatalf("expected ErrInvalidArgument on unsafe DeleteObject ID, got %v", err)
	}
	if err := store.DeleteObject(ctx, "non-existent"); !errors.Is(err, ErrObjectNotFound) {
		t.Fatalf("expected ErrObjectNotFound on DeleteObject, got %v", err)
	}
	if _, err := store.IsChunkReferenced(ctx, "bad-hash"); !errors.Is(err, ErrInvalidArgument) {
		t.Fatalf("expected ErrInvalidArgument on IsChunkReferenced bad hash, got %v", err)
	}

	// Verify loadFromDisk rejects a .pb file whose filename does not match its embedded ObjectMetadata.Id.
	badObjBytes, err := proto.Marshal(&lumavaultv1.ObjectMetadata{Id: "embedded-id"})
	if err != nil {
		t.Fatalf("proto.Marshal: %v", err)
	}
	if err := os.WriteFile(filepath.Join(rootDir, "objects", "wrong-filename.pb"), badObjBytes, 0o644); err != nil {
		t.Fatalf("WriteFile wrong-filename.pb: %v", err)
	}
	if _, err := NewLocalMetadataStore(rootDir); err == nil {
		t.Fatalf("expected NewLocalMetadataStore to fail when filename does not match embedded object ID")
	}
}
