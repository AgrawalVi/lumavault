package metadata

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"slices"
	"sort"
	"strings"
	"time"

	lumavaultv1 "github.com/AgrawalVi/lumavault/gen/go/lumavault/v1"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// dedupKey identifies an object by (namespace, sha256_digest) for idempotent CommitObject deduplication.
type dedupKey struct {
	namespace lumavaultv1.Namespace
	sha256    string
}

// pageCursor encodes the deterministic pagination position for ListObjects.
type pageCursor struct {
	CreatedAtNanos int64  `json:"t,omitempty"`
	SaveVersion    uint32 `json:"v,omitempty"`
	BySaveVersion  bool   `json:"s,omitempty"`
	ID             string `json:"id"`
}

// Engine is a pure deterministic in-memory metadata state machine.
// All mutating transitions accept explicit objectID and timestamp arguments and perform
// zero disk or network I/O, allowing LocalMetadataStore (Day 1) and PaxosMetadataStore (Project 6)
// to share identical validation, deduplication, save versioning, indexing, and chunk refcounting.
//
// Callers must synchronize access to Engine externally (e.g., via sync.RWMutex or a single-threaded
// consensus apply loop).
type Engine struct {
	objects      map[string]*lumavaultv1.ObjectMetadata
	dedupIndex   map[dedupKey]string
	saveVersions map[string]uint32
	chunkRefs    map[string]int
}

// NewEngine returns an initialized, empty deterministic metadata Engine.
func NewEngine() *Engine {
	return &Engine{
		objects:      make(map[string]*lumavaultv1.ObjectMetadata),
		dedupIndex:   make(map[dedupKey]string),
		saveVersions: make(map[string]uint32),
		chunkRefs:    make(map[string]int),
	}
}

// Restore populates the Engine from persisted objects and high-water save version counters.
// All inputs are validated before replacing the Engine's state; if an error is returned,
// the existing Engine state remains untouched.
func (e *Engine) Restore(objects []*lumavaultv1.ObjectMetadata, saveVersions map[string]uint32) error {
	sorted := make([]*lumavaultv1.ObjectMetadata, len(objects))
	seenIDs := make(map[string]struct{}, len(objects))
	for i, obj := range objects {
		if obj == nil || !isSafeObjectID(obj.Id) {
			return fmt.Errorf("%w: cannot restore nil or invalid-ID object", ErrInvalidArgument)
		}
		if _, dup := seenIDs[obj.Id]; dup {
			return fmt.Errorf("%w: duplicate object ID %q in Restore", ErrInvalidArgument, obj.Id)
		}
		seenIDs[obj.Id] = struct{}{}
		sorted[i] = cloneObject(obj)
	}

	// Sort by CreatedAt ASC, ID ASC so deduplication index population is deterministic.
	sort.Slice(sorted, func(i, j int) bool {
		return compareObjectsAsc(sorted[i], sorted[j]) < 0
	})

	newObjects := make(map[string]*lumavaultv1.ObjectMetadata, len(sorted))
	newDedup := make(map[dedupKey]string)
	newSaveVersions := make(map[string]uint32, len(saveVersions))
	newChunkRefs := make(map[string]int)

	for romID, ver := range saveVersions {
		if ver > 0 {
			newSaveVersions[romID] = ver
		}
	}

	for _, obj := range sorted {
		newObjects[obj.Id] = obj
		if isDeduplicatable(obj.Namespace, obj.GetGameMetadata()) {
			key := dedupKey{namespace: obj.Namespace, sha256: obj.Sha256Digest}
			if _, exists := newDedup[key]; !exists {
				newDedup[key] = obj.Id
			}
		}
		if obj.Namespace == lumavaultv1.Namespace_NAMESPACE_GAMES {
			if romID := obj.GetGameMetadata().GetParentRomObjectId(); romID != "" {
				if ver := obj.GetGameMetadata().GetSaveVersion(); ver > newSaveVersions[romID] {
					newSaveVersions[romID] = ver
				}
			}
		}
		adjustChunkRefsMap(newChunkRefs, obj, +1)
	}

	e.objects = newObjects
	e.dedupIndex = newDedup
	e.saveVersions = newSaveVersions
	e.chunkRefs = newChunkRefs
	return nil
}

// CommitObject validates req and either returns an existing deduplicated object or commits
// a new ObjectMetadata record with the supplied objectID and timestamp.
func (e *Engine) CommitObject(req *lumavaultv1.CommitObjectRequest, objectID string, now time.Time) (*lumavaultv1.ObjectMetadata, bool, error) {
	if req == nil {
		return nil, false, fmt.Errorf("%w: request is nil", ErrInvalidArgument)
	}
	if !isSafeObjectID(objectID) {
		return nil, false, fmt.Errorf("%w: invalid objectID %q", ErrInvalidArgument, objectID)
	}
	if err := validateCommitRequest(req); err != nil {
		return nil, false, err
	}

	parentROMID := req.GetGameMetadata().GetParentRomObjectId()
	isGameSave := req.Namespace == lumavaultv1.Namespace_NAMESPACE_GAMES && parentROMID != ""

	if isGameSave {
		parentObj, ok := e.objects[parentROMID]
		if !ok {
			return nil, false, fmt.Errorf("%w: parent_rom_object_id %q does not exist", ErrObjectNotFound, parentROMID)
		}
		if parentObj.Namespace != lumavaultv1.Namespace_NAMESPACE_GAMES || parentObj.GetGameMetadata().GetParentRomObjectId() != "" {
			return nil, false, fmt.Errorf("%w: parent_rom_object_id %q is not a ROM in NAMESPACE_GAMES", ErrInvalidArgument, parentROMID)
		}
	} else if isDeduplicatable(req.Namespace, req.GetGameMetadata()) {
		key := dedupKey{namespace: req.Namespace, sha256: req.Sha256Digest}
		if existingID, ok := e.dedupIndex[key]; ok {
			if existingObj, exists := e.objects[existingID]; exists {
				return cloneObject(existingObj), true, nil
			}
			delete(e.dedupIndex, key)
		}
	}

	if _, exists := e.objects[objectID]; exists {
		return nil, false, fmt.Errorf("%w: object ID %q already exists", ErrInvalidArgument, objectID)
	}

	ts := timestamppb.New(now.UTC())
	obj := &lumavaultv1.ObjectMetadata{
		Id:                 objectID,
		Namespace:          req.Namespace,
		Filename:           req.Filename,
		MimeType:           req.MimeType,
		SizeBytes:          req.SizeBytes,
		ChunkSizeBytes:     req.ChunkSizeBytes,
		Sha256Digest:       req.Sha256Digest,
		ChunkHashes:        slices.Clone(req.ChunkHashes),
		ThumbnailChunkHash: req.ThumbnailChunkHash,
		CreatedAt:          ts,
		UpdatedAt:          cloneTimestamp(ts),
	}

	switch dm := req.DomainMetadata.(type) {
	case *lumavaultv1.CommitObjectRequest_PhotoMetadata:
		if dm.PhotoMetadata != nil {
			obj.DomainMetadata = &lumavaultv1.ObjectMetadata_PhotoMetadata{
				PhotoMetadata: proto.Clone(dm.PhotoMetadata).(*lumavaultv1.PhotoMetadata),
			}
		}
	case *lumavaultv1.CommitObjectRequest_CinemaMetadata:
		if dm.CinemaMetadata != nil {
			obj.DomainMetadata = &lumavaultv1.ObjectMetadata_CinemaMetadata{
				CinemaMetadata: proto.Clone(dm.CinemaMetadata).(*lumavaultv1.CinemaMetadata),
			}
		}
	case *lumavaultv1.CommitObjectRequest_GameMetadata:
		if dm.GameMetadata != nil {
			gm := proto.Clone(dm.GameMetadata).(*lumavaultv1.GameMetadata)
			if isGameSave {
				nextVer := e.saveVersions[parentROMID] + 1
				e.saveVersions[parentROMID] = nextVer
				gm.SaveVersion = nextVer
			} else {
				gm.SaveVersion = 0
			}
			obj.DomainMetadata = &lumavaultv1.ObjectMetadata_GameMetadata{
				GameMetadata: gm,
			}
		}
	}

	e.objects[objectID] = obj
	if isDeduplicatable(obj.Namespace, obj.GetGameMetadata()) {
		e.dedupIndex[dedupKey{namespace: obj.Namespace, sha256: obj.Sha256Digest}] = objectID
	}
	adjustChunkRefsMap(e.chunkRefs, obj, +1)

	return cloneObject(obj), false, nil
}

// GetObject retrieves a deep-cloned ObjectMetadata by ID, or returns ErrObjectNotFound.
func (e *Engine) GetObject(objectID string) (*lumavaultv1.ObjectMetadata, error) {
	if !isSafeObjectID(objectID) {
		return nil, fmt.Errorf("%w: invalid object_id %q", ErrInvalidArgument, objectID)
	}
	obj, ok := e.objects[objectID]
	if !ok {
		return nil, fmt.Errorf("%w: %q", ErrObjectNotFound, objectID)
	}
	return cloneObject(obj), nil
}

// ListObjects filters, sorts, and paginates objects within a required namespace.
func (e *Engine) ListObjects(req *lumavaultv1.ListObjectsRequest) (*lumavaultv1.ListObjectsResponse, error) {
	if req == nil {
		return nil, fmt.Errorf("%w: request is nil", ErrInvalidArgument)
	}
	if !isValidNamespace(req.Namespace) {
		return nil, fmt.Errorf("%w: valid namespace is required", ErrInvalidArgument)
	}
	if req.PageSize < 0 {
		return nil, fmt.Errorf("%w: page_size (%d) must not be negative", ErrInvalidArgument, req.PageSize)
	}

	pageSize := int(req.PageSize)
	if pageSize == 0 {
		pageSize = DefaultPageSize
	} else if pageSize > MaxPageSize {
		pageSize = MaxPageSize
	}

	sortBySaveVersion := req.ParentRomObjectId != ""
	var cursor *pageCursor
	if req.PageToken != "" {
		c, err := decodePageToken(req.PageToken, sortBySaveVersion)
		if err != nil {
			return nil, err
		}
		cursor = c
	}

	var matched []*lumavaultv1.ObjectMetadata
	for _, obj := range e.objects {
		if obj.Namespace != req.Namespace {
			continue
		}
		if req.AlbumId != "" {
			pm := obj.GetPhotoMetadata()
			if pm == nil || !slices.Contains(pm.AlbumIds, req.AlbumId) {
				continue
			}
		}
		if req.ParentRomObjectId != "" {
			gm := obj.GetGameMetadata()
			if gm == nil || gm.ParentRomObjectId != req.ParentRomObjectId {
				continue
			}
		}
		if req.Console != "" {
			gm := obj.GetGameMetadata()
			if gm == nil || gm.Console != req.Console {
				continue
			}
		}
		matched = append(matched, obj)
	}

	sort.Slice(matched, func(i, j int) bool {
		return compareObjectsDesc(matched[i], matched[j], sortBySaveVersion) < 0
	})

	startIdx := 0
	if cursor != nil {
		startIdx = sort.Search(len(matched), func(i int) bool {
			return isAfterCursor(matched[i], cursor, sortBySaveVersion)
		})
	}

	if startIdx >= len(matched) {
		return &lumavaultv1.ListObjectsResponse{}, nil
	}

	endIdx := startIdx + pageSize
	var nextToken string
	if endIdx < len(matched) {
		last := matched[endIdx-1]
		nextToken = encodePageToken(last, sortBySaveVersion)
	} else {
		endIdx = len(matched)
	}

	page := make([]*lumavaultv1.ObjectMetadata, 0, endIdx-startIdx)
	for _, obj := range matched[startIdx:endIdx] {
		page = append(page, cloneObject(obj))
	}

	return &lumavaultv1.ListObjectsResponse{
		Objects:       page,
		NextPageToken: nextToken,
	}, nil
}

// UpdateObjectMetadata applies a partial update to an existing object using req.UpdateMask.
func (e *Engine) UpdateObjectMetadata(req *lumavaultv1.UpdateObjectMetadataRequest, now time.Time) (*lumavaultv1.ObjectMetadata, error) {
	if req == nil || req.Object == nil || !isSafeObjectID(req.Object.Id) {
		return nil, fmt.Errorf("%w: object and valid object.id are required", ErrInvalidArgument)
	}
	if req.UpdateMask == nil || len(req.UpdateMask.Paths) == 0 {
		return nil, fmt.Errorf("%w: non-empty update_mask is required", ErrInvalidArgument)
	}

	existing, ok := e.objects[req.Object.Id]
	if !ok {
		return nil, fmt.Errorf("%w: %q", ErrObjectNotFound, req.Object.Id)
	}

	updated := cloneObject(existing)
	src := req.Object

	for _, path := range req.UpdateMask.Paths {
		if err := applyFieldMaskPath(updated, existing, src, path); err != nil {
			return nil, err
		}
	}

	updated.UpdatedAt = timestamppb.New(now.UTC())

	// Update chunk reference counts if thumbnail_chunk_hash changed.
	if existing.ThumbnailChunkHash != updated.ThumbnailChunkHash {
		adjustChunkRefsMap(e.chunkRefs, existing, -1)
		adjustChunkRefsMap(e.chunkRefs, updated, +1)
	}

	e.objects[updated.Id] = updated
	return cloneObject(updated), nil
}

// DeleteObject removes objectID from the Engine and updates deduplication and chunk reference indexes.
// High-water save_version counters are intentionally preserved so deleted save versions are never reused.
func (e *Engine) DeleteObject(objectID string) error {
	if !isSafeObjectID(objectID) {
		return fmt.Errorf("%w: invalid object_id %q", ErrInvalidArgument, objectID)
	}
	existing, ok := e.objects[objectID]
	if !ok {
		return fmt.Errorf("%w: %q", ErrObjectNotFound, objectID)
	}

	delete(e.objects, objectID)

	if isDeduplicatable(existing.Namespace, existing.GetGameMetadata()) {
		key := dedupKey{namespace: existing.Namespace, sha256: existing.Sha256Digest}
		if e.dedupIndex[key] == objectID {
			delete(e.dedupIndex, key)
			// Deterministically select the earliest remaining object with the same (namespace, sha256)
			// using the same (CreatedAt ASC, Id ASC) ordering as Restore.
			var best *lumavaultv1.ObjectMetadata
			for _, candidate := range e.objects {
				if candidate.Namespace == existing.Namespace &&
					candidate.Sha256Digest == existing.Sha256Digest &&
					isDeduplicatable(candidate.Namespace, candidate.GetGameMetadata()) {
					if best == nil || compareObjectsAsc(candidate, best) < 0 {
						best = candidate
					}
				}
			}
			if best != nil {
				e.dedupIndex[key] = best.Id
			}
		}
	}

	adjustChunkRefsMap(e.chunkRefs, existing, -1)
	return nil
}

// IsChunkReferenced reports whether hash is a valid SHA-256 digest currently referenced by at least one object.
func (e *Engine) IsChunkReferenced(hash string) (bool, error) {
	if err := ValidateHash(hash); err != nil {
		return false, err
	}
	return e.chunkRefs[hash] > 0, nil
}

func (e *Engine) hasObject(objectID string) bool {
	_, ok := e.objects[objectID]
	return ok
}

func (e *Engine) saveVersionsSnapshot() map[string]uint32 {
	out := make(map[string]uint32, len(e.saveVersions))
	for k, v := range e.saveVersions {
		out[k] = v
	}
	return out
}

func (e *Engine) setSaveVersion(parentROMID string, version uint32) {
	if version == 0 {
		delete(e.saveVersions, parentROMID)
	} else {
		e.saveVersions[parentROMID] = version
	}
}

func (e *Engine) putObjectDirect(obj *lumavaultv1.ObjectMetadata) {
	if obj == nil || !isSafeObjectID(obj.Id) {
		return
	}
	cloned := cloneObject(obj)
	if prev, ok := e.objects[cloned.Id]; ok {
		adjustChunkRefsMap(e.chunkRefs, prev, -1)
	}
	e.objects[cloned.Id] = cloned
	adjustChunkRefsMap(e.chunkRefs, cloned, +1)
}

func adjustChunkRefsMap(refs map[string]int, obj *lumavaultv1.ObjectMetadata, delta int) {
	seen := make(map[string]struct{}, len(obj.ChunkHashes)+1)
	for _, h := range obj.ChunkHashes {
		if h == "" {
			continue
		}
		seen[h] = struct{}{}
	}
	if obj.ThumbnailChunkHash != "" {
		seen[obj.ThumbnailChunkHash] = struct{}{}
	}
	for h := range seen {
		next := refs[h] + delta
		if next <= 0 {
			delete(refs, h)
		} else {
			refs[h] = next
		}
	}
}

func validateCommitRequest(req *lumavaultv1.CommitObjectRequest) error {
	if !isValidNamespace(req.Namespace) {
		return fmt.Errorf("%w: invalid or unspecified namespace %v", ErrInvalidArgument, req.Namespace)
	}

	switch dm := req.DomainMetadata.(type) {
	case nil:
		// Optional on CommitObject unless domain requires specific fields.
	case *lumavaultv1.CommitObjectRequest_PhotoMetadata:
		if req.Namespace != lumavaultv1.Namespace_NAMESPACE_PHOTOS || dm.PhotoMetadata == nil {
			return fmt.Errorf("%w: photo_metadata is only valid for NAMESPACE_PHOTOS", ErrInvalidArgument)
		}
	case *lumavaultv1.CommitObjectRequest_CinemaMetadata:
		if req.Namespace != lumavaultv1.Namespace_NAMESPACE_CINEMA || dm.CinemaMetadata == nil {
			return fmt.Errorf("%w: cinema_metadata is only valid for NAMESPACE_CINEMA", ErrInvalidArgument)
		}
	case *lumavaultv1.CommitObjectRequest_GameMetadata:
		if req.Namespace != lumavaultv1.Namespace_NAMESPACE_GAMES || dm.GameMetadata == nil {
			return fmt.Errorf("%w: game_metadata is only valid for NAMESPACE_GAMES", ErrInvalidArgument)
		}
	default:
		return fmt.Errorf("%w: unsupported domain_metadata type", ErrInvalidArgument)
	}

	if err := ValidateHash(req.Sha256Digest); err != nil {
		return fmt.Errorf("sha256_digest: %w", err)
	}
	if req.ThumbnailChunkHash != "" {
		if err := ValidateHash(req.ThumbnailChunkHash); err != nil {
			return fmt.Errorf("thumbnail_chunk_hash: %w", err)
		}
	}
	for i, h := range req.ChunkHashes {
		if err := ValidateHash(h); err != nil {
			return fmt.Errorf("chunk_hashes[%d]: %w", i, err)
		}
	}

	if req.ChunkSizeBytes > MaxChunkSizeBytes {
		return fmt.Errorf("%w: chunk_size_bytes (%d) exceeds max (%d)", ErrInvalidArgument, req.ChunkSizeBytes, MaxChunkSizeBytes)
	}

	if req.SizeBytes == 0 {
		if len(req.ChunkHashes) != 0 {
			return fmt.Errorf("%w: size_bytes is 0 but len(chunk_hashes) is %d", ErrInvalidArgument, len(req.ChunkHashes))
		}
	} else {
		if req.ChunkSizeBytes == 0 {
			return fmt.Errorf("%w: chunk_size_bytes must be > 0 when size_bytes > 0", ErrInvalidArgument)
		}
		expectedChunks := 1 + (req.SizeBytes-1)/uint64(req.ChunkSizeBytes)
		if uint64(len(req.ChunkHashes)) != expectedChunks {
			return fmt.Errorf("%w: len(chunk_hashes)=%d does not match ceil(size_bytes=%d / chunk_size_bytes=%d)=%d",
				ErrInvalidArgument, len(req.ChunkHashes), req.SizeBytes, req.ChunkSizeBytes, expectedChunks)
		}
	}

	return nil
}

func applyFieldMaskPath(updated, existing, src *lumavaultv1.ObjectMetadata, path string) error {
	switch path {
	case "filename":
		updated.Filename = src.Filename
	case "mime_type":
		updated.MimeType = src.MimeType
	case "thumbnail_chunk_hash":
		if src.ThumbnailChunkHash != "" {
			if err := ValidateHash(src.ThumbnailChunkHash); err != nil {
				return fmt.Errorf("thumbnail_chunk_hash: %w", err)
			}
		}
		updated.ThumbnailChunkHash = src.ThumbnailChunkHash

	// PhotoMetadata paths
	case "photo_metadata":
		if updated.Namespace != lumavaultv1.Namespace_NAMESPACE_PHOTOS {
			return fmt.Errorf("%w: path %q is only valid for NAMESPACE_PHOTOS", ErrInvalidArgument, path)
		}
		if src.GetPhotoMetadata() == nil {
			updated.DomainMetadata = nil
		} else {
			updated.DomainMetadata = &lumavaultv1.ObjectMetadata_PhotoMetadata{
				PhotoMetadata: proto.Clone(src.GetPhotoMetadata()).(*lumavaultv1.PhotoMetadata),
			}
		}
	case "photo_metadata.live_photo_pair_id":
		pm, err := ensurePhotoMetadata(updated, path)
		if err != nil {
			return err
		}
		pm.LivePhotoPairId = src.GetPhotoMetadata().GetLivePhotoPairId()
	case "photo_metadata.taken_at":
		pm, err := ensurePhotoMetadata(updated, path)
		if err != nil {
			return err
		}
		pm.TakenAt = cloneTimestamp(src.GetPhotoMetadata().GetTakenAt())
	case "photo_metadata.latitude":
		pm, err := ensurePhotoMetadata(updated, path)
		if err != nil {
			return err
		}
		pm.Latitude = src.GetPhotoMetadata().GetLatitude()
	case "photo_metadata.longitude":
		pm, err := ensurePhotoMetadata(updated, path)
		if err != nil {
			return err
		}
		pm.Longitude = src.GetPhotoMetadata().GetLongitude()
	case "photo_metadata.width":
		pm, err := ensurePhotoMetadata(updated, path)
		if err != nil {
			return err
		}
		pm.Width = src.GetPhotoMetadata().GetWidth()
	case "photo_metadata.height":
		pm, err := ensurePhotoMetadata(updated, path)
		if err != nil {
			return err
		}
		pm.Height = src.GetPhotoMetadata().GetHeight()
	case "photo_metadata.camera_make":
		pm, err := ensurePhotoMetadata(updated, path)
		if err != nil {
			return err
		}
		pm.CameraMake = src.GetPhotoMetadata().GetCameraMake()
	case "photo_metadata.camera_model":
		pm, err := ensurePhotoMetadata(updated, path)
		if err != nil {
			return err
		}
		pm.CameraModel = src.GetPhotoMetadata().GetCameraModel()
	case "photo_metadata.album_ids":
		pm, err := ensurePhotoMetadata(updated, path)
		if err != nil {
			return err
		}
		pm.AlbumIds = slices.Clone(src.GetPhotoMetadata().GetAlbumIds())

	// CinemaMetadata paths
	case "cinema_metadata":
		if updated.Namespace != lumavaultv1.Namespace_NAMESPACE_CINEMA {
			return fmt.Errorf("%w: path %q is only valid for NAMESPACE_CINEMA", ErrInvalidArgument, path)
		}
		if src.GetCinemaMetadata() == nil {
			updated.DomainMetadata = nil
		} else {
			updated.DomainMetadata = &lumavaultv1.ObjectMetadata_CinemaMetadata{
				CinemaMetadata: proto.Clone(src.GetCinemaMetadata()).(*lumavaultv1.CinemaMetadata),
			}
		}
	case "cinema_metadata.playback_position_ms":
		cm, err := ensureCinemaMetadata(updated, path)
		if err != nil {
			return err
		}
		cm.PlaybackPositionMs = src.GetCinemaMetadata().GetPlaybackPositionMs()
	case "cinema_metadata.duration_ms":
		cm, err := ensureCinemaMetadata(updated, path)
		if err != nil {
			return err
		}
		cm.DurationMs = src.GetCinemaMetadata().GetDurationMs()
	case "cinema_metadata.tmdb_id":
		cm, err := ensureCinemaMetadata(updated, path)
		if err != nil {
			return err
		}
		cm.TmdbId = src.GetCinemaMetadata().GetTmdbId()
	case "cinema_metadata.title":
		cm, err := ensureCinemaMetadata(updated, path)
		if err != nil {
			return err
		}
		cm.Title = src.GetCinemaMetadata().GetTitle()
	case "cinema_metadata.overview":
		cm, err := ensureCinemaMetadata(updated, path)
		if err != nil {
			return err
		}
		cm.Overview = src.GetCinemaMetadata().GetOverview()
	case "cinema_metadata.poster_url":
		cm, err := ensureCinemaMetadata(updated, path)
		if err != nil {
			return err
		}
		cm.PosterUrl = src.GetCinemaMetadata().GetPosterUrl()
	case "cinema_metadata.backdrop_url":
		cm, err := ensureCinemaMetadata(updated, path)
		if err != nil {
			return err
		}
		cm.BackdropUrl = src.GetCinemaMetadata().GetBackdropUrl()
	case "cinema_metadata.release_year":
		cm, err := ensureCinemaMetadata(updated, path)
		if err != nil {
			return err
		}
		cm.ReleaseYear = src.GetCinemaMetadata().GetReleaseYear()
	case "cinema_metadata.season_number":
		cm, err := ensureCinemaMetadata(updated, path)
		if err != nil {
			return err
		}
		cm.SeasonNumber = src.GetCinemaMetadata().GetSeasonNumber()
	case "cinema_metadata.episode_number":
		cm, err := ensureCinemaMetadata(updated, path)
		if err != nil {
			return err
		}
		cm.EpisodeNumber = src.GetCinemaMetadata().GetEpisodeNumber()

	// GameMetadata paths
	case "game_metadata":
		if updated.Namespace != lumavaultv1.Namespace_NAMESPACE_GAMES {
			return fmt.Errorf("%w: path %q is only valid for NAMESPACE_GAMES", ErrInvalidArgument, path)
		}
		srcGM := src.GetGameMetadata()
		existingGM := existing.GetGameMetadata()
		if srcGM == nil && existingGM.GetParentRomObjectId() == "" {
			updated.DomainMetadata = nil
			return nil
		}
		if srcGM != nil {
			if srcGM.ParentRomObjectId != "" && srcGM.ParentRomObjectId != existingGM.GetParentRomObjectId() {
				return fmt.Errorf("%w: game_metadata.parent_rom_object_id is immutable", ErrInvalidArgument)
			}
			if srcGM.SaveVersion != 0 && srcGM.SaveVersion != existingGM.GetSaveVersion() {
				return fmt.Errorf("%w: game_metadata.save_version is immutable", ErrInvalidArgument)
			}
		}
		gm, err := ensureGameMetadata(updated, path)
		if err != nil {
			return err
		}
		gm.Console = srcGM.GetConsole()
		gm.IgdbId = srcGM.GetIgdbId()
		gm.BoxArtUrl = srcGM.GetBoxArtUrl()
		gm.SaveKind = srcGM.GetSaveKind()
	case "game_metadata.console":
		gm, err := ensureGameMetadata(updated, path)
		if err != nil {
			return err
		}
		gm.Console = src.GetGameMetadata().GetConsole()
	case "game_metadata.igdb_id":
		gm, err := ensureGameMetadata(updated, path)
		if err != nil {
			return err
		}
		gm.IgdbId = src.GetGameMetadata().GetIgdbId()
	case "game_metadata.box_art_url":
		gm, err := ensureGameMetadata(updated, path)
		if err != nil {
			return err
		}
		gm.BoxArtUrl = src.GetGameMetadata().GetBoxArtUrl()
	case "game_metadata.save_kind":
		gm, err := ensureGameMetadata(updated, path)
		if err != nil {
			return err
		}
		gm.SaveKind = src.GetGameMetadata().GetSaveKind()

	default:
		return fmt.Errorf("%w: unsupported or immutable update_mask path %q", ErrInvalidArgument, path)
	}
	return nil
}

func ensurePhotoMetadata(obj *lumavaultv1.ObjectMetadata, path string) (*lumavaultv1.PhotoMetadata, error) {
	if obj.Namespace != lumavaultv1.Namespace_NAMESPACE_PHOTOS {
		return nil, fmt.Errorf("%w: path %q is only valid for NAMESPACE_PHOTOS", ErrInvalidArgument, path)
	}
	if obj.GetPhotoMetadata() == nil {
		obj.DomainMetadata = &lumavaultv1.ObjectMetadata_PhotoMetadata{
			PhotoMetadata: &lumavaultv1.PhotoMetadata{},
		}
	}
	return obj.GetPhotoMetadata(), nil
}

func ensureCinemaMetadata(obj *lumavaultv1.ObjectMetadata, path string) (*lumavaultv1.CinemaMetadata, error) {
	if obj.Namespace != lumavaultv1.Namespace_NAMESPACE_CINEMA {
		return nil, fmt.Errorf("%w: path %q is only valid for NAMESPACE_CINEMA", ErrInvalidArgument, path)
	}
	if obj.GetCinemaMetadata() == nil {
		obj.DomainMetadata = &lumavaultv1.ObjectMetadata_CinemaMetadata{
			CinemaMetadata: &lumavaultv1.CinemaMetadata{},
		}
	}
	return obj.GetCinemaMetadata(), nil
}

func ensureGameMetadata(obj *lumavaultv1.ObjectMetadata, path string) (*lumavaultv1.GameMetadata, error) {
	if obj.Namespace != lumavaultv1.Namespace_NAMESPACE_GAMES {
		return nil, fmt.Errorf("%w: path %q is only valid for NAMESPACE_GAMES", ErrInvalidArgument, path)
	}
	if obj.GetGameMetadata() == nil {
		obj.DomainMetadata = &lumavaultv1.ObjectMetadata_GameMetadata{
			GameMetadata: &lumavaultv1.GameMetadata{},
		}
	}
	return obj.GetGameMetadata(), nil
}

func isValidNamespace(ns lumavaultv1.Namespace) bool {
	switch ns {
	case lumavaultv1.Namespace_NAMESPACE_PHOTOS,
		lumavaultv1.Namespace_NAMESPACE_CINEMA,
		lumavaultv1.Namespace_NAMESPACE_GAMES:
		return true
	default:
		return false
	}
}

func isDeduplicatable(ns lumavaultv1.Namespace, gm *lumavaultv1.GameMetadata) bool {
	switch ns {
	case lumavaultv1.Namespace_NAMESPACE_PHOTOS:
		return true
	case lumavaultv1.Namespace_NAMESPACE_GAMES:
		return gm.GetParentRomObjectId() == ""
	default:
		return false
	}
}

func isSafeObjectID(id string) bool {
	if id == "" || id == "." || id == ".." {
		return false
	}
	return !strings.ContainsAny(id, `/\`)
}

func compareObjectsAsc(a, b *lumavaultv1.ObjectMetadata) int {
	ta := a.GetCreatedAt().AsTime().UnixNano()
	tb := b.GetCreatedAt().AsTime().UnixNano()
	if ta != tb {
		if ta < tb {
			return -1
		}
		return 1
	}
	if a.Id < b.Id {
		return -1
	}
	if a.Id > b.Id {
		return 1
	}
	return 0
}

func compareObjectsDesc(a, b *lumavaultv1.ObjectMetadata, sortBySaveVersion bool) int {
	if sortBySaveVersion {
		va := a.GetGameMetadata().GetSaveVersion()
		vb := b.GetGameMetadata().GetSaveVersion()
		if va != vb {
			if va > vb {
				return -1
			}
			return 1
		}
	} else {
		ta := a.GetCreatedAt().AsTime().UnixNano()
		tb := b.GetCreatedAt().AsTime().UnixNano()
		if ta != tb {
			if ta > tb {
				return -1
			}
			return 1
		}
	}
	if a.Id < b.Id {
		return -1
	}
	if a.Id > b.Id {
		return 1
	}
	return 0
}

func isAfterCursor(obj *lumavaultv1.ObjectMetadata, c *pageCursor, sortBySaveVersion bool) bool {
	if sortBySaveVersion {
		v := obj.GetGameMetadata().GetSaveVersion()
		if v != c.SaveVersion {
			return v < c.SaveVersion
		}
		return obj.Id > c.ID
	}
	t := obj.GetCreatedAt().AsTime().UnixNano()
	if t != c.CreatedAtNanos {
		return t < c.CreatedAtNanos
	}
	return obj.Id > c.ID
}

func encodePageToken(obj *lumavaultv1.ObjectMetadata, sortBySaveVersion bool) string {
	c := pageCursor{
		BySaveVersion: sortBySaveVersion,
		ID:            obj.Id,
	}
	if sortBySaveVersion {
		c.SaveVersion = obj.GetGameMetadata().GetSaveVersion()
	} else {
		c.CreatedAtNanos = obj.GetCreatedAt().AsTime().UnixNano()
	}
	b, _ := json.Marshal(c)
	return base64.RawURLEncoding.EncodeToString(b)
}

func decodePageToken(token string, sortBySaveVersion bool) (*pageCursor, error) {
	b, err := base64.RawURLEncoding.DecodeString(token)
	if err != nil {
		return nil, fmt.Errorf("%w: invalid page_token encoding: %v", ErrInvalidArgument, err)
	}
	var c pageCursor
	if err := json.Unmarshal(b, &c); err != nil || c.ID == "" {
		return nil, fmt.Errorf("%w: malformed page_token payload", ErrInvalidArgument)
	}
	if c.BySaveVersion != sortBySaveVersion {
		return nil, fmt.Errorf("%w: page_token sort mode does not match query", ErrInvalidArgument)
	}
	return &c, nil
}

func cloneObject(obj *lumavaultv1.ObjectMetadata) *lumavaultv1.ObjectMetadata {
	if obj == nil {
		return nil
	}
	return proto.Clone(obj).(*lumavaultv1.ObjectMetadata)
}

func cloneTimestamp(ts *timestamppb.Timestamp) *timestamppb.Timestamp {
	if ts == nil {
		return nil
	}
	return proto.Clone(ts).(*timestamppb.Timestamp)
}
