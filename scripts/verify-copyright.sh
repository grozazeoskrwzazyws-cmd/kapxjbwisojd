#!/usr/bin/env bash
set -euo pipefail

expected='// Copyright © 2026 Kro. KroGram original materials.'
failed=0
count=0

while IFS= read -r -d '' file; do
    count=$((count + 1))
    IFS= read -r first_line < "$file" || first_line=''
    if [[ "$first_line" != "$expected" ]]; then
        printf 'Missing or changed KroGram copyright header: %s\n' "$file" >&2
        failed=1
    fi
done < <(find KroGram/KroGram KroGram/KroGramTests -type f -name '*.swift' -print0)

if (( count == 0 )); then
    printf 'No Swift source files found to verify.\n' >&2
    exit 1
fi

if ! grep -Fqx 'Copyright (c) 2026 Kro' LICENSE; then
    printf 'LICENSE must retain the Kro copyright notice.\n' >&2
    failed=1
fi

exit "$failed"
