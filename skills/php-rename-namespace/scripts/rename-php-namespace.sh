#!/usr/bin/env bash
set -euo pipefail

# rename-php-namespace.sh - Deterministic PHP namespace renaming
#
# Replaces a PHP namespace prefix across all PHP source files and config files
# in a single pass. Handles two escaping contexts:
#   - Single backslash (PHP files, XML): PhoneBurner\LinkTortilla
#   - Double backslash (JSON, YAML, neon): PhoneBurner\\LinkTortilla
#
# Usage: rename-php-namespace.sh <old-namespace> <new-namespace> [directory]
# Example: rename-php-namespace.sh 'PhoneBurner\LinkTortilla' 'WickedByte\LinkTortilla' .

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <old-namespace> <new-namespace> [directory]"
    echo "Example: $0 'PhoneBurner\\LinkTortilla' 'WickedByte\\LinkTortilla' ."
    exit 1
fi

OLD_NS="$1"
NEW_NS="$2"
DIR="${3:-.}"

# --- Escaping ---
# For sed patterns matching single-backslash content (PHP files):
OLD_SED="${OLD_NS//\\/\\\\}"
NEW_SED="${NEW_NS//\\/\\\\}"

# For sed patterns matching double-backslash content (JSON, neon, etc.):
OLD_DBL="${OLD_NS//\\/\\\\\\\\}"
NEW_DBL="${NEW_NS//\\/\\\\\\\\}"

EXCLUDE_DIRS="--exclude-dir=vendor --exclude-dir=.git --exclude-dir=node_modules"

echo "Renaming namespace: ${OLD_NS} -> ${NEW_NS}"
echo "Directory: ${DIR}"
echo ""

# 1. Single-backslash context: PHP files, XML configs
echo "=== PHP files (single-backslash context) ==="
grep -rl ${EXCLUDE_DIRS} --include="*.php" --include="*.xml" --include="*.phpt" "${OLD_SED}" "${DIR}" 2>/dev/null | while IFS= read -r file; do
    echo "  ${file}"
done || true
grep -rlZ ${EXCLUDE_DIRS} --include="*.php" --include="*.xml" --include="*.phpt" "${OLD_SED}" "${DIR}" 2>/dev/null | xargs -0 -r sed -i "s|${OLD_SED}|${NEW_SED}|g" || true

echo ""

# 2. Double-backslash context: JSON, YAML, neon, dist files
echo "=== Config files (double-backslash context) ==="
grep -rl ${EXCLUDE_DIRS} --include="*.json" --include="*.neon" --include="*.neon.dist" --include="*.yml" --include="*.yaml" "${OLD_DBL}" "${DIR}" 2>/dev/null | while IFS= read -r file; do
    echo "  ${file}"
done || true
grep -rlZ ${EXCLUDE_DIRS} --include="*.json" --include="*.neon" --include="*.neon.dist" --include="*.yml" --include="*.yaml" "${OLD_DBL}" "${DIR}" 2>/dev/null | xargs -0 -r sed -i "s|${OLD_DBL}|${NEW_DBL}|g" || true

echo ""

# 3. Verification
echo "=== Verification ==="
REMAIN_SINGLE=$(grep -rl ${EXCLUDE_DIRS} --include="*.php" --include="*.xml" --include="*.phpt" "${OLD_SED}" "${DIR}" 2>/dev/null || true)
REMAIN_DBL=$(grep -rl ${EXCLUDE_DIRS} --include="*.json" --include="*.neon" --include="*.neon.dist" --include="*.yml" --include="*.yaml" "${OLD_DBL}" "${DIR}" 2>/dev/null || true)

if [[ -z "$REMAIN_SINGLE" && -z "$REMAIN_DBL" ]]; then
    echo "  OK: No remaining references to old namespace."
else
    echo "  WARNING: Old namespace still found in:"
    [[ -n "$REMAIN_SINGLE" ]] && echo "$REMAIN_SINGLE" | sed 's/^/    /'
    [[ -n "$REMAIN_DBL" ]] && echo "$REMAIN_DBL" | sed 's/^/    /'
    exit 1
fi