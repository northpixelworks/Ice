# Agent Guide

This repository supports both Codex and Claude Code with one shared source of durable guidance.

## Entrypoints

- Codex automatically reads `AGENTS.md` files before work and layers global, repository, and nested instructions by directory precedence.
- Claude Code reads `AGENTS.md` natively when no `CLAUDE.md` exists, so `AGENTS.md` is the only instruction file.
- Keep tool-specific settings in tool-specific folders only when needed: `.claude/` for Claude hooks or subagents, and Codex config outside the repo unless a project profile is intentionally versioned.

## Harness Engineering Practices

- Treat the repository as the system of record for architecture, product behavior, commands, quality bars, and known debt.
- Keep root instruction files compact; link to docs for detail.
- Convert repeated review feedback into tests, scripts, docs, lint rules, or checklists.
- Prefer boring, inspectable dependencies and explicit boundaries.
- Make validation easy to run locally and in automation.

## Maintenance

- Update `AGENTS.md` when common commands, setup, architecture, or safety rules change.
- Do not add a `CLAUDE.md`; put Claude-only notes in a `## Claude Code specifics` section of `AGENTS.md` (create it when needed).
- Add nested `AGENTS.md` files only for subtree-specific rules, and list them under "Folder guides" in the root `AGENTS.md`.
- If future Claude hooks are added in `.claude/settings.json`, reference project scripts through `$CLAUDE_PROJECT_DIR` so they work from any current directory.

## Sources

- OpenAI Codex AGENTS.md guide: https://developers.openai.com/codex/guides/agents-md
- Anthropic Claude Code memory guide: https://docs.anthropic.com/en/docs/claude-code/memory
- Anthropic Claude Code hooks reference: https://docs.anthropic.com/en/docs/claude-code/hooks
- Anthropic Claude Code subagents guide: https://docs.anthropic.com/en/docs/claude-code/sub-agents
- OpenAI Harness engineering post: https://openai.com/index/harness-engineering/
