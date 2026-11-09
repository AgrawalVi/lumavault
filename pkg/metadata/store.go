// Package metadata defines the control-plane MetadataStore interface,
// the deterministic in-memory metadata state machine (Engine), and the
// Day-1 per-object LocalMetadataStore implementation.
package metadata

import (
	"context"
	"errors"
	"fmt"

	lumavaultv1 "github.com/AgrawalVi/lumavault/gen/go/lumavault/v1"
)

const (
	// MaxChunkSizeBytes is the maximum allowed chunk slice size (64 MiB).
	MaxChunkSizeBytes = 64 << 20

	// DefaultPageSize is the default number of objects returned by ListObjects when page_size is 0.
	DefaultPageSize = 50

	// MaxPageSize is the maximum number of objects returned in a single ListObjects response.
	MaxPageSize = 200

	// sha256HexLength is the exact character length of a hex-encoded SHA-256 digest.
	sha256HexLength = 64
)

var (
	// ErrObjectNotFound is returned when a requested object_id does not exist.
	ErrObjectNotFound = errors.New("metadata: object not found")

	// ErrInvalidArgument is returned when a request fails validation, contains invalid SHA-256 digests,
	// violates chunk size/count invariants, or specifies an empty or disallowed FieldMask.
	ErrInvalidArgument = errors.New("metadata: invalid argument")
)

// MetadataStore is the pluggable Control Plane storage contract for content-addressed
// object manifests, idempotent (namespace, sha256_digest) deduplication, storage-level
// metadata updates, and chunk reference tracking.
//
// Application-layer domain metadata (albums/EXIF/Live Photos, TMDB catalog/playback state,
// IGDB catalog/game save lineage) lives in the shared PostgreSQL application database
// referencing ObjectMetadata.id.
//
// The Gateway (pkg/gateway) interacts exclusively with this interface, allowing seamless
// upgrades from the Day-1 LocalMetadataStore to the Project 6 Multi-Paxos replicated store.
type MetadataStore interface {
	// CommitObject validates and commits an object manifest.
	// By default it is idempotent on (namespace, sha256_digest), returning the existing
	// ObjectMetadata with deduplicated=true unless req.SkipDedup is true.
	CommitObject(ctx context.Context, req *lumavaultv1.CommitObjectRequest) (obj *lumavaultv1.ObjectMetadata, deduplicated bool, err error)

	// GetObject retrieves a single object's metadata and chunk manifest by ID.
	// Returns ErrObjectNotFound if the object does not exist.
	GetObject(ctx context.Context, objectID string) (*lumavaultv1.ObjectMetadata, error)

	// ListObjects lists objects within a required namespace with deterministic cursor pagination.
	ListObjects(ctx context.Context, req *lumavaultv1.ListObjectsRequest) (*lumavaultv1.ListObjectsResponse, error)

	// UpdateObjectMetadata partially updates mutable storage-level metadata fields
	// (filename, mime_type, thumbnail_chunk_hash) according to a required, non-empty FieldMask.
	UpdateObjectMetadata(ctx context.Context, req *lumavaultv1.UpdateObjectMetadataRequest) (*lumavaultv1.ObjectMetadata, error)

	// DeleteObject deletes an object's metadata record and decrements its chunk reference counts.
	// Returns ErrObjectNotFound if the object does not exist.
	DeleteObject(ctx context.Context, objectID string) error

	// IsChunkReferenced reports whether at least one committed object currently references
	// the given 64-character lowercase hex SHA-256 chunk hash (in chunk_hashes or thumbnail_chunk_hash).
	IsChunkReferenced(ctx context.Context, hash string) (bool, error)
}

// ValidateHash verifies that hash is a canonical 64-character lowercase hexadecimal SHA-256 digest.
// Returns ErrInvalidArgument if the hash is malformed.
func ValidateHash(hash string) error {
	if len(hash) != sha256HexLength {
		return fmt.Errorf("%w: hash %q must be %d lowercase hex characters", ErrInvalidArgument, hash, sha256HexLength)
	}
	for i := 0; i < len(hash); i++ {
		c := hash[i]
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return fmt.Errorf("%w: hash %q contains non-lowercase-hex character %q at index %d", ErrInvalidArgument, hash, c, i)
		}
	}
	return nil
}
