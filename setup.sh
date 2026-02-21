#!/bin/bash

# JSON Claims Integrity DSL - Quick Start Script

set -e

echo "=== JSON Claims Integrity DSL Setup ==="
echo

# Check prerequisites
echo "Checking prerequisites..."

if ! command -v stack &> /dev/null; then
    echo "❌ Haskell Stack not found. Please install from: https://docs.haskellstack.org/en/stable/install_and_upgrade/"
    exit 1
fi

if ! command -v mix &> /dev/null; then
    echo "❌ Elixir/Mix not found. Please install from: https://elixir-lang.org/install.html"
    exit 1
fi

echo "✓ Prerequisites found"
echo

# Build Haskell engine
echo "Building Haskell DSL engine..."
cd haskell_engine
stack build
echo "✓ Haskell engine built successfully"
echo

# Install Phoenix dependencies
echo "Installing Phoenix dependencies..."
cd ../phoenix_web
mix deps.get
mix assets.setup
echo "✓ Phoenix dependencies installed"
echo

# Return to project root
cd ..

echo
echo "=== Setup Complete! ==="
echo
echo "To start the application:"
echo
echo "1. Start the Haskell backend (in terminal 1):"
echo "   cd haskell_engine && stack run"
echo
echo "2. Start the Phoenix frontend (in terminal 2):"
echo "   cd phoenix_web && mix phx.server"
echo
echo "3. Open your browser to: http://localhost:4000/rules"
echo
