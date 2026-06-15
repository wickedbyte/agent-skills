# AGENTS.md

This file provides guidance to Claude Code (claude.ai/code) and other AI coding agents when working with code in this
repository.

> **Always edit `AGENTS.md`, never `CLAUDE.md`.** `CLAUDE.md` is an intentional symlink to `AGENTS.md` so a single
> instruction file serves Claude Code (which looks for `CLAUDE.md`) and other agents (which look for `AGENTS.md`)
> without drift. Writing through the symlink risks clobbering it and splitting the two names into separate files — edit
> the real target, `AGENTS.md`, and the symlink follows automatically.

## What this repository is

A **Claude Code plugin** (`wickedbyte`) that distributes a collection of open agent skills for AI coding agents. There
is no application to build, run, or serve — the deliverables are the skills themselves: Markdown instruction files (and
the occasional helper script) that get loaded into an agent's context. "Working in this repo" almost always means
authoring or editing a skill, not writing application code.

Plugin metadata lives in `.claude-plugin/plugin.json` (name, version, author, repo). Bump its `version` in lockstep with
a new `CHANGELOG.md` entry on release — the CHANGELOG follows Keep a Changelog v2 + SemVer.

## Skill anatomy

Each skill is a directory under `skills/<skill-name>/` containing:

- `SKILL.md` — the entry point, with YAML frontmatter (`name`, `description`, optional `license`) followed by the
  instructions. Keep this lean.
- `references/*.md` — optional deep-detail files referenced _by name_ from `SKILL.md`. The agent reads them only when a
  task needs them.
- Bundled assets (e.g. `php-rename-namespace/rename-php-namespace.sh`) when a skill ships executable tooling.

This is **progressive disclosure**: `SKILL.md` gives defaults and a triage/decision table, and points to `references/`
for the rationale and edge cases. Don't inline everything into `SKILL.md`; don't strand important guidance in a
reference file the entry never mentions.

### The `description` field is the trigger, not a summary

A skill only fires when its `description` matches the user's situation, so descriptions are written as exhaustive **"use
when…"** clauses — concrete triggers, file globs (`.ts`, `.tsx`, `page.tsx`), framework names, and "use this even when
the user doesn't explicitly ask." When editing a skill's scope, edit the `description` to match. A vague description is
a broken skill.

`name` in the frontmatter should match the directory in kebab-case. (Note: `php-rename-namespace/SKILL.md` currently has
`name: php-rename namespace` with a space — fix to match its directory if you touch that file.)

## Two kinds of skill in this repo

- **`best-practices-*`** (typescript, react, nextjs) — opinionated, framework-version-pinned style guides targeting a
  **mid-2026 baseline** (TS 6.x, React 19 + Compiler, Next.js 16 App Router, ESLint 10 flat config, Vite 8). These
  deliberately **invert** older advice, so don't "correct" them back toward pre-2025 conventions. They are **layered**:
  `best-practices-react` explicitly builds on `best-practices-typescript` — add React-specific overrides there rather
  than duplicating TS guidance.
- **Task skills** (`php-rename-namespace`, `brand-guidelines-page`) — procedural skills for a specific job, often with a
  phased workflow, a checklist, and (for php-rename) a bundled script that does the real work deterministically.

When writing a `best-practices-*` skill, follow its own established shape: a "One Idea" framing, numbered core defaults,
a quick triage/decision table, a common-mistakes table, and a pre-commit self-check checklist.

## Editing conventions

Enforced by `.editorconfig`:

- UTF-8, LF line endings, final newline, 4-space indent (2 for YAML).
- Trailing whitespace is trimmed **except in Markdown** (where it's significant for line breaks) — most files here are
  Markdown, so don't rely on a trim-on-save habit.

## Authoring workflow

Use the `skill-creator` skill (available via the Skill tool) to scaffold new skills, edit existing ones, and
run/evaluate them — it knows the SKILL.md format and can measure trigger accuracy. Prefer it over hand-rolling a new
skill directory.
