#!/bin/bash
# BrainX Core Engine v1.0
# Unified Memory System - Core Storage Module
#
# Schema unificado para todas las entradas de memoria

set -euo pipefail

# Source configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config/core.conf"

# Ensure all directories exist
init_brainx() {
    mkdir -p "$BRAINX_STORAGE" "$BRAINX_BACKUPS" "$BRAINX_INDEXES" "$BRAINX_WAL" "$BRAINX_CONFIG"
    mkdir -p "$BRAINX_SNAPSHOT_DIR" "$BRAINX_EXPORT_DIR" "$BRAINX_MIGRATION_DIR"
    
    # Create JSONL if not exists
    if [ ! -f "$BRAINX_DB" ]; then
        touch "$BRAINX_DB"
        echo "[]" > "$BRAINX_DB.tmp" && rm "$BRAINX_DB.tmp" 2>/dev/null || true
    fi
    
    # Create WAL if not exists
    if [ ! -f "$BRAINX_WAL_FILE" ]; then
        touch "$BRAINX_WAL_FILE"
    fi
}

# Generate unique ID with timestamp and random
# Format: brainx_YYYYMMDD_XXXXXXXX_XXXX
generate_brainx_id() {
    local date_part=$(date +%Y%m%d)
    local time_part=$(date +%H%M%S%N | cut -c1-8)
    local rand=$(openssl rand -hex 2 | tr '[:lower:]' '[:upper:]')
    echo "brainx_${date_part}_${time_part}_${rand}"
}

# Get ISO timestamp
iso_timestamp() {
    date -Iseconds
}

# Generate brainx entry following unified schema
# Usage: generate_entry <source> <content> [classification] [entities] [relations] [context] [metadata] [tags]
generate_entry() {
    local source="${1:-command}"
    local raw_content="${2:-}"
    local classification="${3:-{}}"
    local entities="${4:-[]}"
    local relations="${5:-[]}"
    local context="${6:-{}}"
    local metadata="${7:-{}}"
    local tags="${8:-[]}"
    
    local id=$(generate_brainx_id)
    local timestamp=$(iso_timestamp)
    
    # Default classification if not provided
    if [ "$classification" = "{}" ]; then
        classification='{"type":"note","tier":"warm","category":"general","confidence":0.5}'
    fi
    
    # Default context if not provided
    if [ "$context" = "{}" ]; then
        local session_id="${BRAINX_SESSION_ID:-default}"
        local agent="${BRAINX_AGENT:-main}"
        local channel="${BRAINX_CHANNEL:-cli}"
        context="{\"session_id\":\"$session_id\",\"agent\":\"$agent\",\"channel\":\"$channel\"}"
    fi
    
    # Build content object
    local processed_content=$(echo "$raw_content" | sed 's/"/\\"/g' | tr '\n' ' ')
    local content_obj="{\"raw\":\"$processed_content\",\"processed\":\"$processed_content\",\"summary\":\"\"}"
    
    # Create the entry
    jq -n \
        --arg id "$id" \
        --arg timestamp "$timestamp" \
        --arg source "$source" \
        --argjson content "$content_obj" \
        --argjson classification "$classification" \
        --argjson entities "$entities" \
        --argjson relations "$relations" \
        --argjson context "$context" \
        --argjson metadata "$metadata" \
        --argjson tags "$tags" \
        '{
            id: $id,
            timestamp: $timestamp,
            source: $source,
            content: $content,
            classification: $classification,
            entities: $entities,
            relations: $relations,
            context: $context,
            metadata: $metadata,
            tags: $tags,
            access_count: 0,
            last_accessed: $timestamp
        }'
}

# Write Ahead Log - Append operation
# Usage: wal_append <operation> <data_hash>
wal_append() {
    local operation="${1:-}"
    local data_hash="${2:-}"
    local timestamp=$(iso_timestamp)
    
    if [ -n "$operation" ]; then
        echo "[$timestamp] [$operation] [$data_hash]" >> "$BRAINX_WAL_FILE"
    fi
}

# Add entry to brainx
# Usage: brainx_add <type> <content> [options]
# Options: --source, --tier, --category, --tags, --entities, --confidence
brainx_add() {
    init_brainx
    
    local type="${1:-note}"
    local content="${2:-}"
    
    if [ -z "$content" ]; then
        echo "Error: content required" >&2
        return 1
    fi
    
    # Parse optional arguments
    local source="command"
    local tier="warm"
    local category="general"
    local tags="[]"
    local entities="[]"
    local confidence="0.8"
    local session_id="${BRAINX_SESSION_ID:-$(date +%s)}"
    local agent="${BRAINX_AGENT:-main}"
    local channel="${BRAINX_CHANNEL:-cli}"
    
    shift 2  # Remove type and content from args
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --source) source="$2"; shift 2 ;;
            --tier) tier="$2"; shift 2 ;;
            --category) category="$2"; shift 2 ;;
            --tags) tags=$(echo "$2" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$"; ""))'); shift 2 ;;
            --entities) entities="$2"; shift 2 ;;
            --confidence) confidence="$2"; shift 2 ;;
            --session) session_id="$2"; shift 2 ;;
            --agent) agent="$2"; shift 2 ;;
            --channel) channel="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    
    # Build classification
    local classification=$(jq -n \
        --arg type "$type" \
        --arg tier "$tier" \
        --arg category "$category" \
        --argjson confidence "$confidence" \
        '{type: $type, tier: $tier, category: $category, confidence: $confidence}')
    
    # Build context
    local context=$(jq -n \
        --arg session_id "$session_id" \
        --arg agent "$agent" \
        --arg channel "$channel" \
        '{session_id: $session_id, agent: $agent, channel: $channel}')
    
    # Build metadata
    local metadata=$(jq -n \
        --arg extracted_from "" \
        --argjson auto_learned false \
        --argjson verified false \
        '{extracted_from: $extracted_from, auto_learned: $auto_learned, verified: $verified}')
    
    # Generate entry
    local entry=$(generate_entry "$source" "$content" "$classification" "$entities" "[]" "$context" "$metadata" "$tags")
    
    # Compute hash for WAL
    local data_hash=$(echo "$entry" | sha256sum | cut -d' ' -f1)
    
    # Append to WAL first (Layer 1)
    wal_append "ADD" "$data_hash"
    
    # Append to JSONL (Layer 2)
    echo "$entry" >> "$BRAINX_DB"
    
    # Update real-time replica (Layer 3)
    cp "$BRAINX_DB" "$BRAINX_STORAGE/brainx_replica.jsonl" 2>/dev/null || true
    
    # Return the ID
    echo "$entry" | jq -r '.id'
}

# Get entry by ID
# Usage: brainx_get <id>
brainx_get() {
    local id="${1:-}"
    
    if [ -z "$id" ]; then
        echo "Error: id required" >&2
        return 1
    fi
    
    init_brainx
    
    # Search in JSONL
    grep "\"id\":\"$id\"" "$BRAINX_DB" 2>/dev/null | head -1 | jq '.'
}

# Search entries
# Usage: brainx_search <query> [limit]
brainx_search() {
    local query="${1:-}"
    local limit="${2:-10}"
    
    if [ -z "$query" ]; then
        echo "Error: query required" >&2
        return 1
    fi
    
    init_brainx
    
    # Search in content field
    grep -i "$query" "$BRAINX_DB" 2>/dev/null | head -"$limit" | while read -r line; do
        echo "$line" | jq '{
            id: .id,
            timestamp: .timestamp,
            source: .source,
            content: .content.raw,
            tier: .classification.tier,
            category: .classification.category,
            type: .classification.type,
            confidence: .classification.confidence
        }'
    done | jq -s '.'
}

# Update entry access count
# Usage: brainx_touch <id>
brainx_touch() {
    local id="${1:-}"
    
    if [ -z "$id" ]; then
        return 1
    fi
    
    init_brainx
    
    local timestamp=$(iso_timestamp)
    local tmp_file=$(mktemp)
    
    # Read all entries, update matching one
    while IFS= read -r line; do
        if echo "$line" | grep -q "\"id\":\"$id\""; then
            # Update this entry
            echo "$line" | jq --arg ts "$timestamp" '.access_count += 1 | .last_accessed = $ts' >> "$tmp_file"
        else
            echo "$line" >> "$tmp_file"
        fi
    done < "$BRAINX_DB"
    
    mv "$tmp_file" "$BRAINX_DB"
}

# List entries with optional filters
# Usage: brainx_list [--tier tier] [--category cat] [--type type] [--limit n]
brainx_list() {
    local tier=""
    local category=""
    local type=""
    local limit=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --tier) tier="$2"; shift 2 ;;
            --category) category="$2"; shift 2 ;;
            --type) type="$2"; shift 2 ;;
            --limit) limit="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    
    init_brainx
    
    local filter="true"
    [ -n "$tier" ] && filter="$filter and .classification.tier == \"$tier\""
    [ -n "$category" ] && filter="$filter and .classification.category == \"$category\""
    [ -n "$type" ] && filter="$filter and .classification.type == \"$type\""
    
    local cmd="jq -c 'select($filter)' \"$BRAINX_DB\""
    [ -n "$limit" ] && cmd="$cmd | head -$limit"
    
    eval "$cmd" 2>/dev/null | jq -s '.' || echo "[]"
}

# Get statistics
# Usage: brainx_stats
brainx_stats() {
    init_brainx
    
    local total=$(wc -l < "$BRAINX_DB" | tr -d ' ')
    local hot=$(jq 'select(.classification.tier == "hot")' "$BRAINX_DB" 2>/dev/null | wc -l | tr -d ' ')
    local warm=$(jq 'select(.classification.tier == "warm")' "$BRAINX_DB" 2>/dev/null | wc -l | tr -d ' ')
    local cold=$(jq 'select(.classification.tier == "cold")' "$BRAINX_DB" 2>/dev/null | wc -l | tr -d ' ')
    local filesize=$(du -h "$BRAINX_DB" 2>/dev/null | cut -f1 || echo "0B")
    
    jq -n \
        --arg total "$total" \
        --arg hot "$hot" \
        --arg warm "$warm" \
        --arg cold "$cold" \
        --arg filesize "$filesize" \
        --arg version "$BRAINX_VERSION" \
        --arg schema_version "$BRAINX_SCHEMA_VERSION" \
        '{
            total: ($total | tonumber),
            tiers: {
                hot: ($hot | tonumber),
                warm: ($warm | tonumber),
                cold: ($cold | tonumber)
            },
            storage: {
                filesize: $filesize,
                path: "'$BRAINX_DB'",
                wal_path: "'$BRAINX_WAL_FILE'"
            },
            version: $version,
            schema_version: ($schema_version | tonumber)
        }'
}

# Export functions
export -f init_brainx generate_brainx_id iso_timestamp generate_entry
export -f wal_append brainx_add brainx_get brainx_search brainx_touch
export -f brainx_list brainx_stats

# Initialize on source
init_brainx 2>/dev/null || true
