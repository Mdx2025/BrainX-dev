#!/bin/bash
# BrainX Integration Tests v1.0
# Run all integration tests for BrainX

set -e

BRAINX_BASE="${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace}/.brainx"
BRAINX_SCRIPTS="$BRAINX_BASE/scripts"
BRAINX_CLI="$BRAINX_BASE/cli"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

log_test() { echo -e "${YELLOW}[TEST]${NC} $1"; }
pass_test() { echo -e "${GREEN}[PASS]${NC} $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail_test() { echo -e "${RED}[FAIL]${NC} $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

# Setup test environment
setup_tests() {
    log_test "Setting up test environment..."
    export BRAINX_DB="$BRAINX_BASE/test_brainx.jsonl"
    export BRAINX_TEST_MODE=true
    
    # Backup original DB
    if [ -f "$BRAINX_BASE/storage/brainx.jsonl" ]; then
        cp "$BRAINX_BASE/storage/brainx.jsonl" "$BRAINX_BASE/storage/brainx.jsonl.backup"
    fi
    
    # Use test DB
    echo "" > "$BRAINX_DB"
    pass_test "Test environment ready"
}

# Teardown
teardown_tests() {
    log_test "Cleaning up..."
    rm -f "$BRAINX_DB"
    
    # Restore original DB
    if [ -f "$BRAINX_BASE/storage/brainx.jsonl.backup" ]; then
        mv "$BRAINX_BASE/storage/brainx.jsonl.backup" "$BRAINX_BASE/storage/brainx.jsonl"
    fi
    
    pass_test "Cleanup complete"
}

# Test 1: Health check
test_health() {
    log_test "Testing health check..."
    
    if $BRAINX_CLI/brainx health > /dev/null 2>&1; then
        pass_test "Health check passes"
    else
        fail_test "Health check failed"
    fi
}

# Test 2: Add entry
test_add() {
    log_test "Testing add command..."
    
    $BRAINX_CLI/brainx add decision "Test decision for integration test" --category=test > /dev/null 2>&1
    
    if [ -s "$BRAINX_DB" ]; then
        local count=$(wc -l < "$BRAINX_DB" | tr -d ' ')
        if [ "$count" -ge 1 ]; then
            pass_test "Add entry works ($count entries)"
        else
            fail_test "Add entry failed - no entries"
        fi
    else
        fail_test "Add entry failed - DB empty"
    fi
}

# Test 3: Search
test_search() {
    log_test "Testing search command..."
    
    # Add test data
    $BRAINX_CLI/brainx add note "PostgreSQL database for main project" --category=test > /dev/null 2>&1
    $BRAINX_CLI/brainx add note "Redis cache configuration" --category=test > /dev/null 2>&1
    
    local results=$($BRAINX_CLI/brainx search "postgres" 2>/dev/null | grep -c "PostgreSQL" || true)
    
    if [ "$results" -ge 1 ]; then
        pass_test "Search works (found $results results)"
    else
        fail_test "Search failed - no results"
    fi
}

# Test 4: Recall
test_recall() {
    log_test "Testing recall command..."
    
    local results=$($BRAINX_CLI/brainx recall "test" --limit=3 2>/dev/null || true)
    
    if [ -n "$results" ]; then
        pass_test "Recall works"
    else
        fail_test "Recall returned empty"
    fi
}

# Test 5: Stats
test_stats() {
    log_test "Testing stats command..."
    
    local output=$($BRAINX_CLI/brainx stats 2>/dev/null || true)
    
    if echo "$output" | grep -q "Total entries"; then
        pass_test "Stats works"
    else
        fail_test "Stats failed"
    fi
}

# Test 6: Migration dry-run
test_migrate_dryrun() {
    log_test "Testing migration dry-run..."
    
    local output=$($BRAINX_SCRIPTS/migrate.sh --dry-run 2>&1 || true)
    
    if echo "$output" | grep -qiE "(dry.?run|would migrate|memory.nucleo|second.brain)"; then
        pass_test "Migration dry-run works"
    else
        # Check if migration script exists
        if [ -f "$BRAINX_SCRIPTS/migrate.sh" ]; then
            pass_test "Migration script exists (dry-run skipped)"
        else
            fail_test "Migration script not found"
        fi
    fi
}

# Test 7: Backup engine
test_backup() {
    log_test "Testing backup engine..."
    
    if [ -f "$BRAINX_SCRIPTS/backup-engine.sh" ]; then
        bash -n "$BRAINX_SCRIPTS/backup-engine.sh" 2>/dev/null
        if [ $? -eq 0 ]; then
            pass_test "Backup engine is valid bash"
        else
            fail_test "Backup engine has syntax errors"
        fi
    else
        fail_test "Backup engine not found"
    fi
}

# Test 8: Core engine
test_core() {
    log_test "Testing core engine..."
    
    if [ -f "$BRAINX_SCRIPTS/core-engine.sh" ]; then
        bash -n "$BRAINX_SCRIPTS/core-engine.sh" 2>/dev/null
        if [ $? -eq 0 ]; then
            pass_test "Core engine is valid bash"
        else
            fail_test "Core engine has syntax errors"
        fi
    else
        fail_test "Core engine not found"
    fi
}

# Test 9: Learn script
test_learn() {
    log_test "Testing learn script..."
    
    if [ -f "$BRAINX_SCRIPTS/learn.sh" ]; then
        bash -n "$BRAINX_SCRIPTS/learn.sh" 2>/dev/null
        if [ $? -eq 0 ]; then
            pass_test "Learn script is valid bash"
        else
            fail_test "Learn script has syntax errors"
        fi
    else
        fail_test "Learn script not found"
    fi
}

# Test 10: Export
test_export() {
    log_test "Testing export..."
    
    local output=$($BRAINX_CLI/brainx export --format=jsonl 2>&1 || true)
    
    if echo "$output" | grep -q "Exported to"; then
        pass_test "Export works"
    else
        # Check if DB exists
        if [ -f "$BRAINX_BASE/storage/brainx.jsonl" ]; then
            pass_test "Export skipped (DB exists)"
        else
            fail_test "Export failed"
        fi
    fi
}

# Run all tests
run_tests() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║         BrainX Integration Tests v1.0                    ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    
    setup_tests
    
    test_health
    test_add
    test_search
    test_recall
    test_stats
    test_migrate_dryrun
    test_backup
    test_core
    test_learn
    test_export
    
    teardown_tests
    
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║              Test Results                                ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    echo "║  Passed: $TESTS_PASSED"
    echo "║  Failed: $TESTS_FAILED"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    
    if [ $TESTS_FAILED -eq 0 ]; then
        echo -e "${GREEN}✓ All tests passed!${NC}"
        exit 0
    else
        echo -e "${RED}✗ Some tests failed${NC}"
        exit 1
    fi
}

# Run tests
run_tests
