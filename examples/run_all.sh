#!/bin/bash
# Run all RAG library examples
#
# Prerequisites:
#   - Set GEMINI_API_KEY environment variable
#   - For vector_store.exs: API calls are made but no database required
#
# Usage:
#   cd /path/to/rag
#   ./examples/run_all.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

echo "========================================"
echo "Running RAG Library Examples"
echo "========================================"
echo ""

# Check for API key
if [ -z "$GEMINI_API_KEY" ]; then
    echo "WARNING: GEMINI_API_KEY not set. Some examples may fail."
    echo ""
fi

run_example() {
    local example=$1
    echo "----------------------------------------"
    echo "Running: $example"
    echo "----------------------------------------"
    mix run "examples/$example"
    echo ""
}

# Run examples in order (simplest to most complex)
run_example "basic_chat.exs"
run_example "routing_strategies.exs"
run_example "agent.exs"
run_example "vector_store.exs"

echo "========================================"
echo "All examples completed!"
echo "========================================"
