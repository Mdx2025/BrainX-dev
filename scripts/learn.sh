#!/bin/bash
# BrainX Auto-Learning Engine v1.0
# Extract decisions, actions, and entities from transcripts

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config/core.conf"
source "$SCRIPT_DIR/core-engine.sh"

# Configuration
TRANSCRIPT_DIR="${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace}/transcripts"
LEARNED_DIR="$BRAINX_STORAGE/learned"
CONFIDENCE_THRESHOLD=${BRAINX_CONFIDENCE_THRESHOLD:-0.85}
PATTERN_THRESHOLD=${BRAINX_PATTERN_THRESHOLD:-3}

# Show usage
show_usage() {
    cat << 'EOF'
BrainX Auto-Learning Engine v1.0

Usage: learn.sh [OPTIONS] [transcript_file]

Options:
  --auto           Process all new transcripts automatically
  --decisions      Extract only decisions
  --actions        Extract only actions
  --entities       Extract only entities
  --confidence N   Set confidence threshold (default: 0.85)
  --dry-run        Show what would be learned without saving
  -h, --help       Show this help

Examples:
  learn.sh transcript_20250210.md
  learn.sh --auto
  learn.sh --decisions --confidence 0.9
  learn.sh --auto --dry-run
EOF
}

# Initialize learning system
init_learning() {
    mkdir -p "$LEARNED_DIR"
    mkdir -p "$TRANSCRIPT_DIR"
    
    # Create learned index if not exists
    if [ ! -f "$LEARNED_DIR/learned_index.json" ]; then
        echo '{"processed_files": [], "patterns": {}, "stats": {"total_extracted": 0, "decisions": 0, "actions": 0, "entities": 0}}' > "$LEARNED_DIR/learned_index.json"
    fi
}

# Check if file was already processed
is_processed() {
    local file="$1"
    local hash=$(sha256sum "$file" | cut -d' ' -f1)
    jq -e --arg hash "$hash" '.processed_files | contains([$hash])' "$LEARNED_DIR/learned_index.json" > /dev/null 2>&1
}

# Mark file as processed
mark_processed() {
    local file="$1"
    local hash=$(sha256sum "$file" | cut -d' ' -f1)
    local tmp=$(mktemp)
    jq --arg hash "$hash" '.processed_files += [$hash]' "$LEARNED_DIR/learned_index.json" > "$tmp" && mv "$tmp" "$LEARNED_DIR/learned_index.json"
}

# Extract decisions from content
extract_decisions() {
    local content="$1"
    local decisions=()
    
    # Pattern: "decidí...", "voy a...", "vamos a...", "se determinó..."
    local patterns=(
        "decid[ií].*"
        "voy a.*"
        "vamos a.*"
        "se determin[oó].*"
        "se resolvi[oó].*"
        "acordamos.*"
        "definimos.*"
        "optamos por.*"
        "seleccionamos.*"
        "elegimos.*"
    )
    
    for pattern in "${patterns[@]}"; do
        while IFS= read -r line; do
            [ -n "$line" ] && decisions+=("$line")
        done < <(echo "$content" | grep -iE "^.*$pattern.*$" | head -20)
    done
    
    # Remove duplicates and format
    printf '%s\n' "${decisions[@]}" | sort -u | while read -r decision; do
        [ -n "$decision" ] && echo "$decision"
    done
}

# Extract actions from content
extract_actions() {
    local content="$1"
    local actions=()
    
    # Pattern: action items, tasks, TODOs
    local patterns=(
        "TODO[:]?.*"
        "ACTION[:]?.*"
        "tarea[:]?.*"
        "pendiente[:]?.*"
        "se requiere.*"
        "hay que.*"
        "falta.*"
        "necesitamos.*"
        "deber[ií]amos.*"
    )
    
    for pattern in "${patterns[@]}"; do
        while IFS= read -r line; do
            [ -n "$line" ] && actions+=("$line")
        done < <(echo "$content" | grep -iE "^.*$pattern.*$" | head -20)
    done
    
    printf '%s\n' "${actions[@]}" | sort -u | while read -r action; do
        [ -n "$action" ] && echo "$action"
    done
}

# Extract entities from content
extract_entities() {
    local content="$1"
    local entities=()
    
    # Pattern: Capitalized names, organizations, concepts
    # Extract potential entity names (capitalized words in context)
    while IFS= read -r line; do
        [ -n "$line" ] && entities+=("$line")
    done < <(echo "$content" | grep -oE '\b[A-Z][a-zA-Z]+(\s+[A-Z][a-zA-Z]+)*\b' | sort -u | head -30)
    
    # Also look for patterns like "el proyecto X", "el sistema Y"
    while IFS= read -r line; do
        [ -n "$line" ] && entities+=("$line")
    done < <(echo "$content" | grep -oiE '(proyecto|sistema|plataforma|m[oó]dulo|componente|servicio|API)\s+[A-Z][a-zA-Z0-9_]*' | sort -u | head -20)
    
    printf '%s\n' "${entities[@]}" | sort -u | while read -r entity; do
        [ -n "$entity" ] && echo "$entity"
    done
}

# Calculate confidence score for extracted item
calculate_confidence() {
    local item="$1"
    local type="$2"
    local base_confidence=0.5
    
    # Increase confidence based on patterns
    case "$type" in
        decision)
            # Longer decisions with action verbs have higher confidence
            local words=$(echo "$item" | wc -w)
            if [ "$words" -gt 5 ] && [ "$words" -lt 50 ]; then
                base_confidence=$(echo "$base_confidence + 0.2" | bc)
            fi
            # Contains decision keywords
            if echo "$item" | grep -qiE "(implementar|desarrollar|usar|adoptar|migrar|cambiar|configurar)"; then
                base_confidence=$(echo "$base_confidence + 0.15" | bc)
            fi
            ;;
        action)
            # Actions with clear verbs
            if echo "$item" | grep -qiE "^(TODO|ACTION|tarea|pendiente)"; then
                base_confidence=$(echo "$base_confidence + 0.25" | bc)
            fi
            ;;
        entity)
            # Multi-word entities in context
            local words=$(echo "$item" | wc -w)
            if [ "$words" -gt 1 ]; then
                base_confidence=$(echo "$base_confidence + 0.15" | bc)
            fi
            ;;
    esac
    
    # Cap at 0.95
    if (( $(echo "$base_confidence > 0.95" | bc -l) )); then
        base_confidence=0.95
    fi
    
    echo "$base_confidence"
}

# Add learned item to brainx
add_learned_item() {
    local item="$1"
    local type="$2"
    local source="$3"
    local confidence="$4"
    local dry_run="${5:-false}"
    
    local tier="warm"
    if (( $(echo "$confidence > 0.9" | bc -l) )); then
        tier="hot"
    elif (( $(echo "$confidence < 0.7" | bc -l) )); then
        tier="cold"
    fi
    
    local category="$type"
    
    # Build classification
    local classification=$(jq -n \
        --arg type "$type" \
        --arg tier "$tier" \
        --arg category "$category" \
        --argjson confidence "$confidence" \
        '{type: $type, tier: $tier, category: $category, confidence: $confidence}')
    
    # Build context
    local context=$(jq -n \
        --arg session_id "learned" \
        --arg agent "auto-learn" \
        --arg channel "extraction" \
        '{session_id: $session_id, agent: $agent, channel: $channel}')
    
    # Build metadata
    local metadata=$(jq -n \
        --arg extracted_from "$source" \
        --argjson auto_learned true \
        --argjson verified false \
        '{extracted_from: $extracted_from, auto_learned: $auto_learned, verified: $verified}')
    
    # Generate entry
    local entry=$(generate_entry "auto-learn" "$item" "$classification" "[]" "[]" "$context" "$metadata" "[]")
    
    if [ "$dry_run" = true ]; then
        echo "[DRY-RUN] Would add $type (confidence: $confidence): $item"
    else
        echo "$entry" >> "$BRAINX_DB"
        echo "  + Learned: [$type] ${item:0:60}..."
    fi
}

# Process a single transcript
process_transcript() {
    local file="$1"
    local extract_decisions="${2:-true}"
    local extract_actions="${3:-true}"
    local extract_entities="${4:-true}"
    local dry_run="${5:-false}"
    
    local filename=$(basename "$file")
    echo "Processing: $filename"
    
    local content=$(cat "$file" 2>/dev/null || echo "")
    
    if [ -z "$content" ]; then
        echo "  Warning: Empty file"
        return 1
    fi
    
    local added_count=0
    
    # Extract decisions
    if [ "$extract_decisions" = true ]; then
        while IFS= read -r decision; do
            [ -z "$decision" ] && continue
            local confidence=$(calculate_confidence "$decision" "decision")
            if (( $(echo "$confidence >= $CONFIDENCE_THRESHOLD" | bc -l) )); then
                add_learned_item "$decision" "decision" "$file" "$confidence" "$dry_run"
                added_count=$((added_count + 1))
            fi
        done < <(extract_decisions "$content")
    fi
    
    # Extract actions
    if [ "$extract_actions" = true ]; then
        while IFS= read -r action; do
            [ -z "$action" ] && continue
            local confidence=$(calculate_confidence "$action" "action")
            if (( $(echo "$confidence >= $CONFIDENCE_THRESHOLD" | bc -l) )); then
                add_learned_item "$action" "action" "$file" "$confidence" "$dry_run"
                added_count=$((added_count + 1))
            fi
        done < <(extract_actions "$content")
    fi
    
    # Extract entities
    if [ "$extract_entities" = true ]; then
        while IFS= read -r entity; do
            [ -z "$entity" ] && continue
            local confidence=$(calculate_confidence "$entity" "entity")
            if (( $(echo "$confidence >= $CONFIDENCE_THRESHOLD" | bc -l) )); then
                add_learned_item "$entity" "entity" "$file" "$confidence" "$dry_run"
                added_count=$((added_count + 1))
            fi
        done < <(extract_entities "$content")
    fi
    
    if [ "$dry_run" = false ]; then
        mark_processed "$file"
    fi
    
    echo "  Added $added_count items"
    return $added_count
}

# Auto-process all new transcripts
auto_process() {
    local dry_run="${1:-false}"
    local total_files=0
    local total_items=0
    
    echo "Auto-learning from transcripts in: $TRANSCRIPT_DIR"
    echo ""
    
    if [ ! -d "$TRANSCRIPT_DIR" ]; then
        echo "Warning: Transcript directory not found"
        return 0
    fi
    
    while IFS= read -r -d '' file; do
        # Skip already processed files
        if is_processed "$file"; then
            continue
        fi
        
        total_files=$((total_files + 1))
        process_transcript "$file" true true true "$dry_run"
        total_items=$((total_items + $?))
        
    done < <(find "$TRANSCRIPT_DIR" -name "*.md" -o -name "*.txt" | sort -z)
    
    echo ""
    if [ "$dry_run" = true ]; then
        echo "[DRY-RUN] Would process $total_files files, extracting ~$total_items items"
    else
        echo "Auto-learning complete:"
        echo "  Files processed: $total_files"
        echo "  Items extracted: $total_items"
        
        # Update replica
        cp "$BRAINX_DB" "$BRAINX_STORAGE/brainx_replica.jsonl"
    fi
}

# Main function
main() {
    local file=""
    local auto=false
    local extract_decisions=true
    local extract_actions=true
    local extract_entities=true
    local dry_run=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            --auto)
                auto=true
                shift
                ;;
            --decisions)
                extract_decisions=true
                extract_actions=false
                extract_entities=false
                shift
                ;;
            --actions)
                extract_decisions=false
                extract_actions=true
                extract_entities=false
                shift
                ;;
            --entities)
                extract_decisions=false
                extract_actions=false
                extract_entities=true
                shift
                ;;
            --confidence)
                CONFIDENCE_THRESHOLD="$2"
                shift 2
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            -*)
                echo "Unknown option: $1" >&2
                show_usage
                exit 1
                ;;
            *)
                file="$1"
                shift
                ;;
        esac
    done
    
    # Initialize
    init_learning
    init_brainx
    
    # Run auto mode or single file
    if [ "$auto" = true ]; then
        auto_process "$dry_run"
    elif [ -n "$file" ]; then
        if [ ! -f "$file" ]; then
            echo "Error: File not found: $file" >&2
            exit 1
        fi
        process_transcript "$file" "$extract_decisions" "$extract_actions" "$extract_entities" "$dry_run"
    else
        echo "Error: Specify a file or use --auto" >&2
        show_usage
        exit 1
    fi
}

# Run if executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
