#!/bin/bash
# Run all RAG library examples
#
# Prerequisites:
#   - Set at least one API key: GEMINI_API_KEY, ANTHROPIC_API_KEY, or OPENAI_API_KEY
#   - For database examples: PostgreSQL with pgvector extension
#
# Usage:
#   cd /path/to/rag
#   ./examples/run_all.sh
#
# Options:
#   --skip-db    Skip examples that require database setup
#   --quick      Run only quick examples (no DB, minimal API calls)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

# Parse arguments
SKIP_DB=false
QUICK=false
for arg in "$@"; do
    case $arg in
        --skip-db) SKIP_DB=true ;;
        --quick) QUICK=true ;;
    esac
done

echo "========================================"
echo "Running RAG Library Examples"
echo "========================================"
echo ""

# Check for API keys
API_KEYS_FOUND=false
if [ -n "$GEMINI_API_KEY" ]; then
    echo "✓ GEMINI_API_KEY set"
    API_KEYS_FOUND=true
fi
if [ -n "$ANTHROPIC_API_KEY" ]; then
    echo "✓ ANTHROPIC_API_KEY set"
    API_KEYS_FOUND=true
fi
if [ -n "$OPENAI_API_KEY" ] || [ -n "$CODEX_API_KEY" ]; then
    echo "✓ OPENAI_API_KEY/CODEX_API_KEY set"
    API_KEYS_FOUND=true
fi

if [ "$API_KEYS_FOUND" = false ]; then
    echo "WARNING: No API keys found. Set at least one of:"
    echo "  - GEMINI_API_KEY"
    echo "  - ANTHROPIC_API_KEY"
    echo "  - OPENAI_API_KEY or CODEX_API_KEY"
    echo ""
fi
echo ""

run_example() {
    local example=$1
    local requires_db=${2:-false}
    local requires_rag_demo=${3:-false}

    if [ "$requires_rag_demo" = true ]; then
        echo "----------------------------------------"
        echo "SKIPPING (run from rag_demo): $example"
        echo "  Run with: cd examples/rag_demo && mix run ../$example"
        echo "----------------------------------------"
        echo ""
        return
    fi

    if [ "$requires_db" = true ] && [ "$SKIP_DB" = true ]; then
        echo "----------------------------------------"
        echo "SKIPPING (requires DB): $example"
        echo "----------------------------------------"
        echo ""
        return
    fi

    echo "----------------------------------------"
    echo "Running: $example"
    echo "----------------------------------------"
    mix run "examples/$example"
    echo ""
}

run_triple_store_demo() {
    echo "----------------------------------------"
    echo "Running: triple_store_demo"
    echo "----------------------------------------"
    pushd "$SCRIPT_DIR/triple_store_demo" > /dev/null
    mix deps.get
    mix run -e "TripleStoreDemo.run()"
    popd > /dev/null
    echo ""
}

# ========================================
# QUICK EXAMPLES (no DB, minimal API calls)
# ========================================

echo "=== Basic Examples ==="
run_example "basic_chat.exs"
run_example "routing_strategies.exs"
run_triple_store_demo

if [ "$QUICK" = true ]; then
    echo "========================================"
    echo "Quick examples completed! (--quick mode)"
    echo "========================================"
    exit 0
fi

# ========================================
# STANDARD EXAMPLES (API calls, no DB)
# ========================================

echo "=== Router & Agent Examples ==="
run_example "multi_llm_router.exs"
run_example "agent.exs"

echo "=== Text Processing Examples ==="
run_example "chunking_strategies.exs"
run_example "vector_store.exs"

# ========================================
# ADVANCED EXAMPLES (may require DB)
# ========================================

echo "=== RAG Workflow Examples ==="
run_example "basic_rag.exs" true
run_example "hybrid_search.exs" true

echo "=== GraphRAG Examples ==="
run_example "graph_rag.exs" true

echo "=== Pipeline Examples ==="
run_example "pipeline_example.exs" true true

echo "========================================"
echo "All examples completed!"
echo "========================================"
echo ""
echo "Examples run:"
echo "  - basic_chat.exs"
echo "  - routing_strategies.exs"
echo "  - triple_store_demo"
echo "  - multi_llm_router.exs"
echo "  - agent.exs"
echo "  - chunking_strategies.exs"
echo "  - vector_store.exs"
if [ "$SKIP_DB" = false ]; then
    echo "  - basic_rag.exs"
    echo "  - hybrid_search.exs"
    echo "  - graph_rag.exs"
fi
echo ""
echo "Examples requiring rag_demo (run separately):"
echo "  - pipeline_example.exs  ->  cd examples/rag_demo && mix run ../pipeline_example.exs"
echo ""
echo "For the full demo app with Phoenix integration, see:"
echo "  examples/rag_demo/"
