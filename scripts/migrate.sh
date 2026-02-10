#!/bin/bash
# BrainX Migration Tool v1.0
# Migrate from legacy memory systems

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config/core.conf"
source "$SCRIPT_DIR/core-engine.sh"
source "$SCRIPT_DIR/backup-engine.sh"

# Migration state
DRY_RUN=false
ROLLBACK_FILE=""
MIGRATION_LOG=""

# Show usage
show_usage() {
    cat << 'EOF'
BrainX Migration Tool v1.0

Usage: migrate.sh [OPTIONS] <source>

Sources:
  memory-nucleo    Migrate from memory-nucleo (index.jsonl)
  second-brain     Migrate from second-brain (.md files in CORE/)
  all              Migrate from all available sources

Options:
  --dry-run        Simulate migration without changes
  --rollback       Rollback last migration
  --force          Skip confirmation prompts
  -h, --help       Show this help

Examples:
  migrate.sh memory-nucleo --dry-run
  migrate.sh second-brain
  migrate.sh all --force
  migrate.sh --rollback
EOF
}

# Initialize migration
init_migration() {
    mkdir -p "$BRAINX_MIGRATION_DIR"
    MIGRATION_LOG="$BRAINX_MIGRATION_DIR/migration_$(date +%Y%m%d_%H%M%S).log"
    touch "$MIGRATION_LOG"
}

# Log message
log_migration() {
    local msg="$1"
    local timestamp=$(date -Iseconds)
    echo "[$timestamp] $msg" | tee -a "$MIGRATION_LOG"
}

# Create rollback point
create_rollback_point() {
    local rollback_name="rollback_$(date +%Y%m%d_%H%M%S)"
    ROLLBACK_FILE="$BRAINX_MIGRATION_DIR/${rollback_name}.jsonl"
    
    if [ -f "$BRAINX_DB" ]; then
        cp "$BRAINX_DB" "$ROLLBACK_FILE"
        log_migration "Rollback point created: $ROLLBACK_FILE"
    fi
    
    # Save rollback metadata
    jq -n \
        --arg timestamp "$(date -Iseconds)" \
        --arg rollback_file "$ROLLBACK_FILE" \
        --arg db_hash "$(sha256sum "$BRAINX_DB" 2>/dev/null | cut -d' ' -f1 || echo 'none')" \
        '{created: $timestamp, rollback_file: $rollback_file, db_hash: $db_hash}' > "$BRAINX_MIGRATION_DIR/latest_rollback.json"
}

# Perform rollback
perform_rollback() {
    if [ ! -f "$BRAINX_MIGRATION_DIR/latest_rollback.json" ]; then
        echo "Error: No rollback point found" >&2
        return 1
    fi
    
    local rollback_file=$(jq -r '.rollback_file' "$BRAINX_MIGRATION_DIR/latest_rollback.json")
    local original_hash=$(jq -r '.db_hash' "$BRAINX_MIGRATION_DIR/latest_rollback.json")
    
    if [ ! -f "$rollback_file" ]; then
        echo "Error: Rollback file not found: $rollback_file" >&2
        return 1
    fi
    
    # Verify integrity
    local current_hash=$(sha256sum "$BRAINX_DB" 2>/dev/null | cut -d' ' -f1 || echo 'none')
    
    echo "Rolling back migration..."
    echo "  Rollback file: $rollback_file"
    echo "  Current entries: $(wc -l < "$BRAINX_DB" | tr -d ' ')"
    echo "  Rollback entries: $(wc -l < "$rollback_file" | tr -d ' ')"
    
    cp "$rollback_file" "$BRAINX_DB"
    cp "$BRAINX_DB" "$BRAINX_STORAGE/brainx_replica.jsonl"
    
    echo "✓ Rollback completed successfully"
    log_migration "ROLLBACK performed to $rollback_file"
    
    # Update replica
    cp "$BRAINX_DB" "$BRAINX_STORAGE/brainx_replica.jsonl"
}

# Migrate from memory-nucleo (index.jsonl)
migrate_memory_nucleo() {
    local source_path="${1:-$HOME/.openclaw/workspace/memory-nucleo/index.jsonl}"
    
    if [ ! -f "$source_path" ]; then
        echo "Error: memory-nucleo index not found: $source_path" >&2
        return 1
    fi
    
    log_migration "Starting memory-nucleo migration from: $source_path"
    
    local total=0
    local migrated=0
    local errors=0
    
    while IFS= read -r line; do
        total=$((total + 1))
        
        # Skip empty lines
        [ -z "$line" ] && continue
        
        # Parse memory-nucleo entry
        local id=$(echo "$line" | jq -r '.id // empty')
        local timestamp=$(echo "$line" | jq -r '.timestamp // empty')
        local content=$(echo "$line" | jq -r '.content // empty')
        local type=$(echo "$line" | jq -r '.type // "note"')
        local tags=$(echo "$line" | jq -r '.tags // "[]"')
        local source=$(echo "$line" | jq -r '.source // "memory-nucleo"')
        
        if [ -z "$id" ] || [ -z "$content" ]; then
            log_migration "SKIP: Invalid entry at line $total"
            errors=$((errors + 1))
            continue
        fi
        
        # Map type to BrainX classification
        local tier="warm"
        local category="general"
        case "$type" in
            critical|hot) tier="hot" ;;
            decision|action) category="decision" ;;
            entity) category="entity" ;;
            insight) category="insight" ;;
        esac
        
        # Build classification
        local classification=$(jq -n \
            --arg type "$type" \
            --arg tier "$tier" \
            --arg category "$category" \
            '{type: $type, tier: $tier, category: $category, confidence: 0.7}')
        
        # Build context
        local context=$(jq -n \
            --arg session_id "migrated" \
            --arg agent "migration" \
            --arg channel "import" \
            '{session_id: $session_id, agent: $agent, channel: $channel}')
        
        # Build metadata
        local metadata=$(jq -n \
            --arg extracted_from "$source_path" \
            --argjson auto_learned false \
            --argjson verified false \
            --arg original_id "$id" \
            '{extracted_from: $extracted_from, auto_learned: $auto_learned, verified: $verified, original_id: $original_id}')
        
        # Generate BrainX entry
        local entry=$(generate_entry "$source" "$content" "$classification" "[]" "[]" "$context" "$metadata" "$tags")
        
        if [ "$DRY_RUN" = true ]; then
            echo "[DRY-RUN] Would migrate: $id -> $(echo "$entry" | jq -r '.id')"
        else
            echo "$entry" >> "$BRAINX_DB"
            log_migration "MIGRATED: $id -> $(echo "$entry" | jq -r '.id')"
        fi
        
        migrated=$((migrated + 1))
        
        # Progress indicator
        if [ $((total % 100)) -eq 0 ]; then
            echo "  Progress: $total processed, $migrated migrated"
        fi
        
    done < "$source_path"
    
    echo ""
    echo "Memory-nucleo migration complete:"
    echo "  Total entries: $total"
    echo "  Migrated: $migrated"
    echo "  Errors: $errors"
    
    log_migration "memory-nucleo migration completed: $migrated/$total entries"
    
    return 0
}

# Migrate from second-brain (.md files)
migrate_second_brain() {
    local source_path="${1:-$HOME/.openclaw/workspace/second-brain/CORE}"
    
    if [ ! -d "$source_path" ]; then
        echo "Error: second-brain directory not found: $source_path" >&2
        return 1
    fi
    
    log_migration "Starting second-brain migration from: $source_path"
    
    local total=0
    local migrated=0
    local errors=0
    
    # Find all .md files
    while IFS= read -r -d '' file; do
        total=$((total + 1))
        
        local filename=$(basename "$file" .md)
        local content=$(cat "$file" 2>/dev/null || echo "")
        
        if [ -z "$content" ]; then
            log_migration "SKIP: Empty file $file"
            errors=$((errors + 1))
            continue
        fi
        
        # Extract title from first line or filename
        local title=$(echo "$content" | head -1 | sed 's/^# //' | tr -d '\n')
        [ -z "$title" ] && title="$filename"
        
        # Extract tags from content (format: #tag)
        local tags=$(echo "$content" | grep -oE '#[a-zA-Z0-9_-]+' | sed 's/^#//' | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo '[]')
        
        # Determine category from file path
        local category="general"
        local dir=$(dirname "$file" | xargs basename)
        case "$dir" in
            DECISIONS|decisions) category="decision" ;;
            PROJECTS|projects) category="project" ;;
            INSIGHTS|insights) category="insight" ;;
            ENTITIES|entities) category="entity" ;;
        esac
        
        # Build classification
        local classification=$(jq -n \
            --arg type "note" \
            --arg tier "warm" \
            --arg category "$category" \
            '{type: $type, tier: $tier, category: $category, confidence: 0.75}')
        
        # Build context
        local context=$(jq -n \
            --arg session_id "migrated" \
            --arg agent "migration" \
            --arg channel "import" \
            '{session_id: $session_id, agent: $agent, channel: $channel}')
        
        # Build metadata
        local metadata=$(jq -n \
            --arg extracted_from "$file" \
            --argjson auto_learned false \
            --argjson verified false \
            --arg original_filename "$filename" \
            '{extracted_from: $extracted_from, auto_learned: $auto_learned, verified: $verified, original_filename: $original_filename}')
        
        # Generate BrainX entry
        local entry=$(generate_entry "second-brain" "$content" "$classification" "[]" "[]" "$context" "$metadata" "$tags")
        
        if [ "$DRY_RUN" = true ]; then
            echo "[DRY-RUN] Would migrate: $filename"
        else
            echo "$entry" >> "$BRAINX_DB"
            log_migration "MIGRATED: $filename -> $(echo "$entry" | jq -r '.id')"
        fi
        
        migrated=$((migrated + 1))
        
        # Progress indicator
        if [ $((total % 50)) -eq 0 ]; then
            echo "  Progress: $total processed, $migrated migrated"
        fi
        
    done < <(find "$source_path" -name "*.md" -type f -print0 2>/dev/null)
    
    echo ""
    echo "Second-brain migration complete:"
    echo "  Total files: $total"
    echo "  Migrated: $migrated"
    echo "  Errors: $errors"
    
    log_migration "second-brain migration completed: $migrated/$total files"
    
    return 0
}

# Main function
main() {
    local source=""
    local force=false
    local rollback=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --rollback)
                rollback=true
                shift
                ;;
            --force)
                force=true
                shift
                ;;
            memory-nucleo|second-brain|all)
                source="$1"
                shift
                ;;
            *)
                echo "Unknown option: $1" >&2
                show_usage
                exit 1
                ;;
        esac
    done
    
    # Initialize
    init_migration
    
    # Handle rollback
    if [ "$rollback" = true ]; then
        perform_rollback
        exit 0
    fi
    
    # Validate source
    if [ -z "$source" ]; then
        echo "Error: Source required" >&2
        show_usage
        exit 1
    fi
    
    # Confirm if not dry-run and not forced
    if [ "$DRY_RUN" = false ] && [ "$force" = false ]; then
        echo "This will migrate data from: $source"
        echo "Target database: $BRAINX_DB"
        read -p "Continue? (yes/no): " confirm
        if [ "$confirm" != "yes" ]; then
            echo "Migration cancelled"
            exit 0
        fi
    fi
    
    # Create backup before migration
    if [ "$DRY_RUN" = false ]; then
        echo "Creating backup before migration..."
        create_rollback_point
        create_snapshot "pre_migration_$(date +%Y%m%d_%H%M%S)"
    fi
    
    # Run migration
    local exit_code=0
    
    case "$source" in
        memory-nucleo)
            migrate_memory_nucleo
            exit_code=$?
            ;;
        second-brain)
            migrate_second_brain
            exit_code=$?
            ;;
        all)
            migrate_memory_nucleo
            local mn_code=$?
            migrate_second_brain
            local sb_code=$?
            exit_code=$((mn_code + sb_code))
            ;;
    esac
    
    # Update replica
    if [ "$DRY_RUN" = false ] && [ $exit_code -eq 0 ]; then
        cp "$BRAINX_DB" "$BRAINX_STORAGE/brainx_replica.jsonl"
        echo ""
        echo "✓ Migration completed successfully"
        echo "  Log file: $MIGRATION_LOG"
    elif [ "$DRY_RUN" = true ]; then
        echo ""
        echo "✓ Dry-run completed (no changes made)"
    else
        echo ""
        echo "✗ Migration completed with errors"
        exit 1
    fi
}

# Run if executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
