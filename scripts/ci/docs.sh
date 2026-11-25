#!/usr/bin/env bash
# CI job: DocC must build without warnings, every public declaration must have
# a doc comment, and docs/*.md and README.md must be the woven output of their
# sources.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

ci_step "swift package generate-documentation"
swift package generate-documentation --target MCP --warnings-as-errors
ci_step "swift scripts/doc-coverage.swift"
swift scripts/doc-coverage.swift
ci_step "swift scripts/weave.swift --check"
swift scripts/weave.swift --check
