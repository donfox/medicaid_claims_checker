#!/bin/bash

# Medicaid Claims Checker - setup script

set -e

# Work from the repository root (this script lives in scripts/).
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "=== Medicaid Claims Checker Setup ==="
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
cd "$ROOT_DIR/haskell_engine"
stack build
echo "✓ Haskell engine built successfully"
echo

# Install Phoenix dependencies
echo "Installing Phoenix dependencies..."
cd "$ROOT_DIR/phoenix_web"
mix deps.get
mix assets.setup
echo "✓ Phoenix dependencies installed"
echo

# Set up database
echo "Setting up database..."
mix ecto.create
mix ecto.migrate
mix run priv/repo/seeds.exs
echo "✓ Database created, migrated, and seeded"
echo

cd "$ROOT_DIR"

echo
echo "=== Setup Complete! ==="
echo
echo "To start the application:"
echo
echo "   scripts/start.sh"
echo
echo "Then open your browser to: http://localhost:4000"
echo
