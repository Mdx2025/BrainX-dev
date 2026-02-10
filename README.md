# BrainX v1.0 🧠

**Personal Knowledge & Memory System for OpenClaw**

BrainX is a unified knowledge management system that replaces multiple legacy memory systems (memory-nucleo, second-brain, etc.) with a single, intelligent, tiered storage system.

## Features

- **🎯 Tiered Storage**: Hot/Warm/Cold access patterns for optimal retrieval
- **🔍 Smart Search**: Content-based search with relevance ranking
- **🤖 Auto-Learning**: Extract decisions, actions, and entities from transcripts
- **📦 Migration**: Import data from legacy systems (memory-nucleo, second-brain)
- **🛡️ Backup & Recovery**: Automatic backups with rollback support
- **🔌 LLM Integration**: Context injection for enhanced responses

## Quick Start

```bash
# Check system health
brainx health

# Add an entry
brainx add decision "Use PostgreSQL for the main database"

# Search knowledge
brainx search "database"

# View stats
brainx stats
```

## Installation

BrainX requires OpenClaw workspace. It's already integrated if you're reading this.

### Prerequisites

- Bash 4.0+
- jq (JSON processor)
- OpenClaw workspace at `~/.openclaw/workspace`

### Setup

```bash
# Verify installation
brainx health

# Run integration tests
~/.openclaw/workspace/.brainx/tests/test-integration.sh
```

## CLI Commands

### `brainx add <type> <content>`

Add a new knowledge entry.

```bash
brainx add decision "Migrate to Kubernetes"
brainx add action "Update documentation"
brainx add note "Meeting with team" --category=work --tags=meeting,team
```

**Options:**
- `--category=<name>`: Assign category
- `--tags=a,b,c`: Add comma-separated tags
- `--tier=hot|warm|cold`: Set access tier

### `brainx search <query>`

Search entries by content.

```bash
brainx search "postgres"
brainx search "migration" --limit=10
brainx search "urgent" --tier=hot
```

### `brainx recall [context]`

Recall relevant entries based on context (uses tier ranking).

```bash
brainx recall "database decision"
brainx recall --limit=5 --days=7
```

### `brainx inject <query>`

Show formatted context for LLM injection.

```bash
brainx inject "what database should I use"
```

### `brainx learn <file>`

Learn from transcript files.

```bash
brainx learn transcript.txt
brainx learn transcript.txt --auto-classify
```

### `brainx migrate`

Migrate data from legacy systems.

```bash
brainx migrate --dry-run      # Preview
brainx migrate                # Run migration
brainx migrate --rollback     # Restore backup
```

### `brainx health`

Check system health and verify all components.

### `brainx stats`

Show database statistics.

```
Total entries:    152
Hot tier:         23
Warm tier:        89
Cold tier:        40
Decisions:        45
Actions:          67
Auto-learned:     12
```

### `brainx export`

Export BrainX data.

```bash
brainx export --format=jsonl
brainx export --format=json
```

## Directory Structure

```
~/.openclaw/workspace/.brainx/
├── cli/
│   └── brainx              # Main CLI
├── scripts/
│   ├── core-engine.sh      # Core functionality
│   ├── backup-engine.sh    # Backup/restore
│   ├── migrate.sh          # Migration tool
│   └── learn.sh            # Auto-learning
├── config/
│   └── core.conf           # Configuration
├── storage/
│   ├── brainx.jsonl        # Main database
│   └── brainx_replica.jsonl # Replica for fast reads
├── indexes/
│   └── *.json              # Generated indexes
├── backups/
│   └── */                  # Timestamped backups
└── tests/
    └── test-integration.sh # Test suite
```

## Data Model

Each BrainX entry is a JSON object:

```json
{
  "id": "bx_1699999999_a1b2c3d4",
  "timestamp": "2024-01-15T10:30:00Z",
  "source": "cli:add",
  "content": {
    "raw": "Original content",
    "processed": "Processed content",
    "summary": "Brief summary"
  },
  "classification": {
    "type": "decision|action|note",
    "tier": "hot|warm|cold",
    "category": "work",
    "confidence": 0.95
  },
  "entities": [...],
  "relations": [...],
  "context": {
    "session_id": "...",
    "agent": "brainx",
    "channel": "cli"
  },
  "metadata": {
    "extracted_from": "cli",
    "auto_learned": false,
    "verified": true
  },
  "tags": ["important", "database"],
  "access_count": 0,
  "last_accessed": "2024-01-15T10:30:00Z"
}
```

## Migration from Legacy Systems

BrainX can import from:

1. **memory-nucleo** (`skills/memory-nucleo/.memory/index.jsonl`)
2. **second-brain** (`second-brain/CORE/{WORK,FAMILY,PERSONAL,PROJECTS}/`)
3. **brainx skill** (`skills/brainx/SKILL.md`)

```bash
# Preview migration
brainx migrate --dry-run

# Run migration (with automatic backup)
brainx migrate

# Rollback if needed
brainx migrate --rollback
```

## Auto-Learning

BrainX can automatically extract knowledge from conversation transcripts:

```bash
# Learn from a specific transcript
brainx learn conversation.txt

# Learn from all new transcripts
brainx learn --auto

# Extract only decisions
brainx learn --decisions

# Extract with higher confidence
brainx learn --confidence 0.9
```

**Extracted patterns:**
- **Decisions**: "decidí...", "vamos a...", "optamos por..."
- **Actions**: "TODO:", "ACTION:", "necesitamos..."
- **Entities**: Projects, people, technologies mentioned

## Configuration

Edit `~/.openclaw/workspace/.brainx/config/core.conf`:

```bash
# Confidence threshold for auto-learning (0.0-1.0)
BRAINX_CONFIDENCE_THRESHOLD=0.85

# Pattern detection threshold
BRAINX_PATTERN_THRESHOLD=3

# Session/agent identification
BRAINX_AGENT="brainx"
BRAINX_SESSION_ID="default"
```

## Testing

Run the integration test suite:

```bash
~/.openclaw/workspace/.brainx/tests/test-integration.sh
```

Tests cover:
- Health checks
- Add/search/recall operations
- Migration dry-run
- Backup engine
- Core functionality

## Troubleshooting

### "Command not found"

Ensure the CLI is in PATH or use full path:
```bash
export PATH="$HOME/.openclaw/workspace/.brainx/cli:$PATH"
```

### "No database found"

Initialize BrainX:
```bash
brainx add note "First entry"  # Creates DB automatically
```

### Migration fails

Check source files exist:
```bash
ls ~/.openclaw/workspace/skills/memory-nucleo/.memory/
ls ~/.openclaw/workspace/second-brain/CORE/
```

## Changelog

### v1.0 (2024-02-10)
- ✅ Unified CLI with all commands
- ✅ Migration from legacy systems
- ✅ Auto-learning from transcripts
- ✅ Tiered storage (hot/warm/cold)
- ✅ Search and recall functionality
- ✅ Backup and rollback support
- ✅ Integration tests

## License

MIT - Part of OpenClaw ecosystem
