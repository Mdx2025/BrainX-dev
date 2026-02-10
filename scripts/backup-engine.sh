#!/bin/bash
# BrainX Backup System v1.0
# 4-Layer Backup Strategy
# Layer 1: Real-time replica
# Layer 2: Write Ahead Log (WAL)
# Layer 3: Snapshot rotation
# Layer 4: Versioned exports

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config/core.conf"

# Initialize backup directories
init_backup_system() {
    mkdir -p "$BRAINX_SNAPSHOT_DIR"
    mkdir -p "$BRAINX_EXPORT_DIR"
    mkdir -p "$BRAINX_MIGRATION_DIR"
    mkdir -p "$BRAINX_BACKUPS/archives"
    
    # Initialize replica if not exists
    if [ ! -f "$BRAINX_STORAGE/brainx_replica.jsonl" ]; then
        touch "$BRAINX_STORAGE/brainx_replica.jsonl"
    fi
}

# Layer 3: Create snapshot
# Usage: create_snapshot [name]
create_snapshot() {
    local name="${1:-$(date +%Y%m%d_%H%M%S)}"
    local snapshot_file="$BRAINX_SNAPSHOT_DIR/brainx_${name}.jsonl"
    
    if [ ! -f "$BRAINX_DB" ]; then
        echo "Error: No database to snapshot" >&2
        return 1
    fi
    
    # Create snapshot with metadata
    local timestamp=$(date -Iseconds)
    local entries=$(wc -l < "$BRAINX_DB" | tr -d ' ')
    local hash=$(sha256sum "$BRAINX_DB" | cut -d' ' -f1)
    
    # Copy with verification
    cp "$BRAINX_DB" "$snapshot_file"
    local snapshot_hash=$(sha256sum "$snapshot_file" | cut -d' ' -f1)
    
    if [ "$hash" != "$snapshot_hash" ]; then
        echo "Error: Snapshot hash mismatch" >&2
        rm -f "$snapshot_file"
        return 1
    fi
    
    # Create metadata
    jq -n \
        --arg name "$name" \
        --arg timestamp "$timestamp" \
        --arg entries "$entries" \
        --arg hash "$hash" \
        --arg file "$snapshot_file" \
        '{
            name: $name,
            created: $timestamp,
            entries: ($entries | tonumber),
            hash: $hash,
            file: $file
        }' > "$BRAINX_SNAPSHOT_DIR/${name}.meta.json"
    
    echo "Snapshot created: $name ($entries entries)"
    echo "$snapshot_file"
}

# Layer 4: Create versioned export
# Usage: create_export [version_name]
create_export() {
    local version_name="${1:-v$(date +%Y%m%d_%H%M%S)}"
    local export_dir="$BRAINX_EXPORT_DIR/$version_name"
    
    mkdir -p "$export_dir"
    
    local timestamp=$(date -Iseconds)
    local entries=$(wc -l < "$BRAINX_DB" | tr -d ' ')
    
    # Export main database
    cp "$BRAINX_DB" "$export_dir/brainx.jsonl"
    
    # Export WAL
    cp "$BRAINX_WAL_FILE" "$export_dir/brainx.wal" 2>/dev/null || true
    
    # Export configuration
    cp -r "$BRAINX_CONFIG" "$export_dir/" 2>/dev/null || true
    
    # Create manifest
    jq -n \
        --arg version "$version_name" \
        --arg timestamp "$timestamp" \
        --arg entries "$entries" \
        --arg schema_version "$BRAINX_SCHEMA_VERSION" \
        '{
            version: $version,
            exported_at: $timestamp,
            schema_version: ($schema_version | tonumber),
            entries: ($entries | tonumber),
            files: ["brainx.jsonl", "brainx.wal", "config/"]
        }' > "$export_dir/manifest.json"
    
    # Create compressed archive
    local archive_name="$BRAINX_BACKUPS/archives/brainx_export_${version_name}.tar.gz"
    tar -czf "$archive_name" -C "$BRAINX_EXPORT_DIR" "$version_name"
    
    echo "Export created: $version_name"
    echo "Archive: $archive_name"
    echo "$export_dir"
}

# List available snapshots
# Usage: list_snapshots
list_snapshots() {
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║                    BrainX Snapshots                        ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    
    local count=0
    for meta in "$BRAINX_SNAPSHOT_DIR"/*.meta.json; do
        [ -f "$meta" ] || continue
        
        local name=$(jq -r '.name' "$meta")
        local created=$(jq -r '.created' "$meta")
        local entries=$(jq -r '.entries' "$meta")
        local file=$(jq -r '.file' "$meta")
        local size=$(du -h "$file" 2>/dev/null | cut -f1 || echo "0B")
        
        echo "[$count] $name"
        echo "    Created: $created"
        echo "    Entries: $entries"
        echo "    Size: $size"
        echo ""
        
        count=$((count + 1))
    done
    
    if [ $count -eq 0 ]; then
        echo "No snapshots available"
    fi
}

# List available exports
# Usage: list_exports
list_exports() {
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║                    BrainX Exports                          ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    
    for archive in "$BRAINX_BACKUPS/archives"/*.tar.gz; do
        [ -f "$archive" ] || continue
        
        local name=$(basename "$archive" .tar.gz)
        local size=$(du -h "$archive" | cut -f1)
        local date=$(stat -c %y "$archive" 2>/dev/null | cut -d' ' -f1)
        
        echo "• $name"
        echo "    Size: $size | Date: $date"
        echo ""
    done
}

# Restore from snapshot
# Usage: restore_snapshot <name> [--force]
restore_snapshot() {
    local name="${1:-}"
    local force=false
    
    if [ "$name" = "--force" ]; then
        force=true
        name=""
    fi
    
    if [ -z "$name" ]; then
        echo "Error: Snapshot name required" >&2
        list_snapshots
        return 1
    fi
    
    local snapshot_file="$BRAINX_SNAPSHOT_DIR/brainx_${name}.jsonl"
    local meta_file="$BRAINX_SNAPSHOT_DIR/${name}.meta.json"
    
    if [ ! -f "$snapshot_file" ]; then
        echo "Error: Snapshot not found: $name" >&2
        return 1
    fi
    
    if [ "$force" != true ]; then
        echo "Warning: This will replace current database" >&2
        read -p "Continue? (yes/no): " confirm
        [ "$confirm" = "yes" ] || return 1
    fi
    
    # Create backup before restore
    create_snapshot "pre_restore_$(date +%Y%m%d_%H%M%S)"
    
    # Copy snapshot to main database
    cp "$snapshot_file" "$BRAINX_DB"
    
    # Update replica
    cp "$BRAINX_DB" "$BRAINX_STORAGE/brainx_replica.jsonl"
    
    echo "Restored from snapshot: $name"
}

# Create full backup (all layers)
# Usage: full_backup
create_full_backup() {
    local backup_name="full_$(date +%Y%m%d_%H%M%S)"
    local backup_dir="$BRAINX_BACKUPS/$backup_name"
    
    echo "Creating full backup: $backup_name"
    mkdir -p "$backup_dir"
    
    # Layer 1 & 2: Database and WAL
    echo "[1/4] Backing up database..."
    cp "$BRAINX_DB" "$backup_dir/"
    cp "$BRAINX_WAL_FILE" "$backup_dir/" 2>/dev/null || true
    cp "$BRAINX_STORAGE/brainx_replica.jsonl" "$backup_dir/" 2>/dev/null || true
    
    # Layer 3: Latest snapshots
    echo "[2/4] Backing up snapshots..."
    cp -r "$BRAINX_SNAPSHOT_DIR" "$backup_dir/" 2>/dev/null || true
    
    # Layer 4: Configuration
    echo "[3/4] Backing up configuration..."
    cp -r "$BRAINX_CONFIG" "$backup_dir/" 2>/dev/null || true
    
    # Create archive
    echo "[4/4] Creating archive..."
    local archive="$BRAINX_BACKUPS/${backup_name}.tar.gz"
    tar -czf "$archive" -C "$BRAINX_BACKUPS" "$backup_name"
    rm -rf "$backup_dir"
    
    # Calculate checksum
    local hash=$(sha256sum "$archive" | cut -d' ' -f1)
    echo "$hash  ${backup_name}.tar.gz" > "$archive.sha256"
    
    echo ""
    echo "Full backup created: $archive"
    echo "SHA256: $hash"
}

# Rotate old snapshots (keep last 28)
# Usage: rotate_snapshots [keep_count]
rotate_snapshots() {
    local keep_count="${1:-28}"
    
    local snapshot_count=$(ls -1 "$BRAINX_SNAPSHOT_DIR"/*.meta.json 2>/dev/null | wc -l)
    
    if [ "$snapshot_count" -le "$keep_count" ]; then
        return 0
    fi
    
    echo "Rotating snapshots: keeping $keep_count of $snapshot_count"
    
    # Get sorted list and remove oldest
    ls -1t "$BRAINX_SNAPSHOT_DIR"/*.meta.json | tail -n +$((keep_count + 1)) | while read -r meta; do
        local name=$(basename "$meta" .meta.json)
        local snapshot="$BRAINX_SNAPSHOT_DIR/brainx_${name}.jsonl"
        
        rm -f "$meta" "$snapshot"
        echo "Removed: $name"
    done
}

# Verify database integrity
# Usage: verify_integrity
verify_integrity() {
    echo "Verifying BrainX database integrity..."
    
    local errors=0
    local total=0
    
    # Check if database exists
    if [ ! -f "$BRAINX_DB" ]; then
        echo "Error: Database file not found" >&2
        return 1
    fi
    
    # Validate each JSON line
    while IFS= read -r line; do
        total=$((total + 1))
        if ! echo "$line" | jq -e '.' > /dev/null 2>&1; then
            echo "Error: Invalid JSON at line $total" >&2
            errors=$((errors + 1))
        fi
        
        # Check required fields
        if ! echo "$line" | jq -e '.id and .timestamp and .content' > /dev/null 2>&1; then
            echo "Error: Missing required fields at line $total" >&2
            errors=$((errors + 1))
        fi
    done < "$BRAINX_DB"
    
    echo ""
    echo "Verification complete:"
    echo "  Total entries: $total"
    echo "  Errors: $errors"
    
    if [ $errors -eq 0 ]; then
        echo "  Status: ✓ OK"
        return 0
    else
        echo "  Status: ✗ FAILED"
        return 1
    fi
}

# Export functions
export -f init_backup_system create_snapshot create_export
export -f list_snapshots list_exports restore_snapshot
export -f create_full_backup rotate_snapshots verify_integrity

# Initialize
init_backup_system
