---
name: php-rename namespace
description: >-
    Use when renaming, replacing, or moving PHP namespaces across a project, including updating use statements, FQCNs,
    composer.json PSR-4 autoload, phpstan.neon, and config files.
license: https://github.com/wickedbyte/agent-skills/blob/main/LICENSE
---

# Rename PHP Namespace

## Overview

Deterministic, single-pass PHP namespace renaming using `./scripts/rename-php-namespace.sh`. Replaces a namespace prefix
across all PHP source and config files in one command instead of editing files individually.

**Core principle:** Use the script for the bulk rename, then verify with grep. Never edit PHP files one-by-one for
namespace renames.

## When to Use

- Renaming a vendor namespace (e.g., `PhoneBurner\LinkTortilla` -> `WickedByte\LinkTortilla`)
- Forking a package and changing ownership namespace
- Reorganizing namespace hierarchy
- Any task involving find-and-replace of a PHP namespace prefix

## The Script

Use `rename-php-namespace.sh` in this skill's scripts directory:

```bash
bash ./scripts/rename-php-namespace.sh \
    'OldVendor\Package' 'NewVendor\Package' /path/to/project
```

**Arguments:** `<old-namespace> <new-namespace> [directory (default: .)]`

Pass namespaces with **single backslashes** in **single quotes** — the script handles all escaping internally.

## What It Handles

| Context                                           | Escaping    | File types                            |
| ------------------------------------------------- | ----------- | ------------------------------------- |
| PHP source (`namespace`, `use`, FQCNs, docblocks) | Single `\`  | `*.php`, `*.xml`, `*.phpt`            |
| Config files (composer.json, phpstan, etc.)       | Double `\\` | `*.json`, `*.neon`, `*.yml`, `*.yaml` |

**Excluded directories:** `vendor/`, `.git/`, `node_modules/`

## Workflow

1. Run the script — it prints which files it modifies and verifies no old references remain
2. Run `composer dump-autoload` if autoload mappings changed
3. Run the project's test suite to confirm correctness
4. If directory structure needs to change (e.g., PSR-4 `src/OldVendor/` -> `src/NewVendor/`), rename directories
   manually — this is separate from namespace string replacement

## Common Mistakes

- **Forgetting `composer dump-autoload`** after changing PSR-4 roots
- **Directory structure mismatch** — the script renames namespace _strings_, not filesystem paths. If PSR-4 maps
  `OldVendor\\` to `src/`, the directory may also need renaming.
- **Using double quotes** on the command line — use single quotes to prevent shell backslash interpretation
- **Partial namespace overlap** — renaming `Acme\Foo` will also affect `Acme\Foo\Bar` (it's a prefix match). This is
  usually correct but verify if you have sibling namespaces like `Acme\FooBar`.
