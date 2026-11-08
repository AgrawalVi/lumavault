package metadata

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	lumavaultv1 "github.com/AgrawalVi/lumavault/gen/go/lumavault/v1"
	"google.golang.org/protobuf/proto"
)

// Compile-time check that LocalMetadataStore implements MetadataStore.
var _ MetadataStore = (*LocalMetadataStore)(nil)

// LocalMetadataStore is the Day-1 filesystem-backed MetadataStore implementation.
// It delegates deterministic validation, indexing, and reference counting to an in-memory
// Engine protected by a sync.RWMutex, and persists one atomic binary Protobuf file per object
// under <rootDir>/objects/<id>.pb alongside high-water game save version counters in
// <rootDir>/save_versions.json.
type LocalMetadataStore struct {
	objectsDir       string
	tmpDir           string
	saveVersionsPath string

	mu     sync.RWMutex
	engine *Engine
}

// NewLocalMetadataStore initializes a LocalMetadataStore rooted at rootDir, creating
// the objects/ and tmp/ subdirectories, cleaning up any orphaned staging files in tmp/,
// and rebuilding all in-memory indexes and chunk reference counts from on-disk state.
func NewLocalMetadataStore(rootDir string) (*LocalMetadataStore, error) {
	if rootDir == "" {
		return nil, errors.New("metadata: rootDir must not be empty")
	}
	cleanRoot := filepath.Clean(rootDir)
	objectsDir := filepath.Join(cleanRoot, "objects")
	tmpDir := filepath.Join(cleanRoot, "tmp")
	saveVersionsPath := filepath.Join(cleanRoot, "save_versions.json")

	if err := os.MkdirAll(objectsDir, 0o755); err != nil {
		return nil, fmt.Errorf("metadata: create objects dir: %w", err)
	}
	// Remove any orphaned meta-* staging files left behind by an interrupted write.
	if err := os.RemoveAll(tmpDir); err != nil {
		return nil, fmt.Errorf("metadata: clean tmp dir: %w", err)
	}
	if err := os.MkdirAll(tmpDir, 0o755); err != nil {
		return nil, fmt.Errorf("metadata: create tmp dir: %w", err)
	}

	s := &LocalMetadataStore{
		objectsDir:       objectsDir,
		tmpDir:           tmpDir,
		saveVersionsPath: saveVersionsPath,
		engine:           NewEngine(),
	}

	if err := s.loadFromDisk(); err != nil {
		return nil, err
	}
	return s, nil
}

// CommitObject validates and commits an object manifest, persisting the resulting
// ObjectMetadata to <rootDir>/objects/<id>.pb atomically.
func (s *LocalMetadataStore) CommitObject(ctx context.Context, req *lumavaultv1.CommitObjectRequest) (*lumavaultv1.ObjectMetadata, bool, error) {
	if err := ctx.Err(); err != nil {
		return nil, false, err
	}
	if req == nil {
		return nil, false, fmt.Errorf("%w: request is nil", ErrInvalidArgument)
	}

	id, err := newUUIDv4()
	if err != nil {
		return nil, false, fmt.Errorf("metadata: generate object id: %w", err)
	}
	now := time.Now().UTC()

	s.mu.Lock()
	defer s.mu.Unlock()

	parentROMID := req.GetGameMetadata().GetParentRomObjectId()
	isGameSave := req.Namespace == lumavaultv1.Namespace_NAMESPACE_GAMES && parentROMID != ""
	var prevSaveVer uint32
	if isGameSave {
		prevSaveVer = s.engine.saveVersions[parentROMID]
	}

	obj, deduplicated, err := s.engine.CommitObject(req, id, now)
	if err != nil {
		return nil, false, err
	}
	if deduplicated {
		return obj, true, nil
	}

	// Persist high-water save_versions.json first (if this was a game save) so a crash
	// never allows a version number to be reused.
	if isGameSave {
		if err := s.writeSaveVersionsLocked(); err != nil {
			_ = s.engine.DeleteObject(obj.Id)
			s.engine.setSaveVersion(parentROMID, prevSaveVer)
			return nil, false, err
		}
	}

	if err := s.writeObjectFile(obj); err != nil {
		_ = s.engine.DeleteObject(obj.Id)
		if isGameSave {
			s.engine.setSaveVersion(parentROMID, prevSaveVer)
			if rbErr := s.writeSaveVersionsLocked(); rbErr != nil {
				// Keep in-memory high-water mark aligned with save_versions.json on disk.
				s.engine.setSaveVersion(parentROMID, obj.GetGameMetadata().GetSaveVersion())
			}
		}
		return nil, false, err
	}

	return obj, false, nil
}

// GetObject retrieves a single object's metadata by ID.
func (s *LocalMetadataStore) GetObject(ctx context.Context, objectID string) (*lumavaultv1.ObjectMetadata, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}

	s.mu.RLock()
	defer s.mu.RUnlock()

	return s.engine.GetObject(objectID)
}

// ListObjects lists objects within a namespace with optional domain filters and cursor pagination.
func (s *LocalMetadataStore) ListObjects(ctx context.Context, req *lumavaultv1.ListObjectsRequest) (*lumavaultv1.ListObjectsResponse, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}

	s.mu.RLock()
	defer s.mu.RUnlock()

	return s.engine.ListObjects(req)
}

// UpdateObjectMetadata partially updates mutable object metadata fields using a FieldMask
// and atomically persists the updated ObjectMetadata to disk.
func (s *LocalMetadataStore) UpdateObjectMetadata(ctx context.Context, req *lumavaultv1.UpdateObjectMetadataRequest) (*lumavaultv1.ObjectMetadata, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if req == nil || req.Object == nil || !isSafeObjectID(req.Object.Id) {
		return nil, fmt.Errorf("%w: object and valid object.id are required", ErrInvalidArgument)
	}

	now := time.Now().UTC()

	s.mu.Lock()
	defer s.mu.Unlock()

	prevObj, err := s.engine.GetObject(req.Object.Id)
	if err != nil {
		return nil, err
	}

	updated, err := s.engine.UpdateObjectMetadata(req, now)
	if err != nil {
		return nil, err
	}

	if err := s.writeObjectFile(updated); err != nil {
		s.engine.putObjectDirect(prevObj)
		return nil, err
	}

	return updated, nil
}

// DeleteObject removes an object's metadata file from disk and updates in-memory indexes
// and chunk reference counts.
func (s *LocalMetadataStore) DeleteObject(ctx context.Context, objectID string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if !isSafeObjectID(objectID) {
		return fmt.Errorf("%w: invalid object_id %q", ErrInvalidArgument, objectID)
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	if !s.engine.hasObject(objectID) {
		return fmt.Errorf("%w: %q", ErrObjectNotFound, objectID)
	}

	objPath := s.objectFilePath(objectID)
	if err := os.Remove(objPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("metadata: remove object file %s: %w", objectID, err)
	}

	return s.engine.DeleteObject(objectID)
}

// IsChunkReferenced checks whether hash is currently referenced by any committed object.
func (s *LocalMetadataStore) IsChunkReferenced(ctx context.Context, hash string) (bool, error) {
	if err := ctx.Err(); err != nil {
		return false, err
	}

	s.mu.RLock()
	defer s.mu.RUnlock()

	return s.engine.IsChunkReferenced(hash)
}

func (s *LocalMetadataStore) loadFromDisk() error {
	saveVersions := make(map[string]uint32)
	if data, err := os.ReadFile(s.saveVersionsPath); err == nil {
		if err := json.Unmarshal(data, &saveVersions); err != nil {
			return fmt.Errorf("metadata: unmarshal save_versions.json: %w", err)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("metadata: read save_versions.json: %w", err)
	}

	entries, err := os.ReadDir(s.objectsDir)
	if err != nil {
		return fmt.Errorf("metadata: read objects dir: %w", err)
	}

	var objects []*lumavaultv1.ObjectMetadata
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".pb") {
			continue
		}
		expectedID := strings.TrimSuffix(entry.Name(), ".pb")
		path := filepath.Join(s.objectsDir, entry.Name())
		raw, err := os.ReadFile(path)
		if err != nil {
			return fmt.Errorf("metadata: read object file %s: %w", entry.Name(), err)
		}
		obj := &lumavaultv1.ObjectMetadata{}
		if err := proto.Unmarshal(raw, obj); err != nil {
			return fmt.Errorf("metadata: unmarshal object file %s: %w", entry.Name(), err)
		}
		if obj.Id != expectedID || !isSafeObjectID(obj.Id) {
			return fmt.Errorf("metadata: object file %s has mismatched or unsafe id %q", entry.Name(), obj.Id)
		}
		objects = append(objects, obj)
	}

	return s.engine.Restore(objects, saveVersions)
}

func (s *LocalMetadataStore) objectFilePath(objectID string) string {
	return filepath.Join(s.objectsDir, objectID+".pb")
}

func (s *LocalMetadataStore) writeObjectFile(obj *lumavaultv1.ObjectMetadata) error {
	if !isSafeObjectID(obj.Id) {
		return fmt.Errorf("%w: unsafe object_id %q", ErrInvalidArgument, obj.Id)
	}
	raw, err := proto.Marshal(obj)
	if err != nil {
		return fmt.Errorf("metadata: marshal object %s: %w", obj.Id, err)
	}
	return s.writeFileAtomic(s.objectFilePath(obj.Id), raw)
}

func (s *LocalMetadataStore) writeSaveVersionsLocked() error {
	snapshot := s.engine.saveVersionsSnapshot()
	raw, err := json.Marshal(snapshot)
	if err != nil {
		return fmt.Errorf("metadata: marshal save_versions.json: %w", err)
	}
	return s.writeFileAtomic(s.saveVersionsPath, raw)
}

func (s *LocalMetadataStore) writeFileAtomic(destPath string, data []byte) (retErr error) {
	tmpFile, err := os.CreateTemp(s.tmpDir, "meta-*")
	if err != nil {
		return fmt.Errorf("metadata: create temp file: %w", err)
	}
	tmpPath := tmpFile.Name()
	closed := false

	defer func() {
		if !closed {
			_ = tmpFile.Close()
		}
		if retErr != nil {
			_ = os.Remove(tmpPath)
		}
	}()

	if _, err := tmpFile.Write(data); err != nil {
		return fmt.Errorf("metadata: write temp file: %w", err)
	}
	if err := tmpFile.Chmod(0o644); err != nil {
		return fmt.Errorf("metadata: chmod temp file: %w", err)
	}
	if err := tmpFile.Sync(); err != nil {
		return fmt.Errorf("metadata: sync temp file: %w", err)
	}
	if err := tmpFile.Close(); err != nil {
		return fmt.Errorf("metadata: close temp file: %w", err)
	}
	closed = true

	if err := os.Rename(tmpPath, destPath); err != nil {
		return fmt.Errorf("metadata: rename temp file to %s: %w", filepath.Base(destPath), err)
	}
	return nil
}

func newUUIDv4() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	b[6] = (b[6] & 0x0f) | 0x40 // Version 4
	b[8] = (b[8] & 0x3f) | 0x80 // Variant 10
	var buf [36]byte
	hex.Encode(buf[0:8], b[0:4])
	buf[8] = '-'
	hex.Encode(buf[9:13], b[4:6])
	buf[13] = '-'
	hex.Encode(buf[14:18], b[6:8])
	buf[18] = '-'
	hex.Encode(buf[19:23], b[8:10])
	buf[23] = '-'
	hex.Encode(buf[24:36], b[10:16])
	return string(buf[:]), nil
}
