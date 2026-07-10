# Agent icons

Brand marks used for the per-session **agent badge** (sidebar rows + tab chips),
replacing the placeholder colored `Circle()` in `SessionRow`. File name maps 1:1
to the `AgentSession.agent` enum case.

| File | Agent | Mark | Fill |
|---|---|---|---|
| `claude.svg` | `.claude` | Claude (asterisk) | brand terracotta `#D97757` |
| `codex.svg` | `.codex` | OpenAI (Codex has no distinct mark) | `currentColor` (tints to theme) |

- **Source:** [Simple Icons](https://simpleicons.org) — `claude` via
  `cdn.simpleicons.org`, `openai` via the `simple-icons` npm package on jsDelivr.
  Both are single-path 24×24 SVGs.
- **`currentColor`:** `codex.svg` (OpenAI's mark) is monochrome — it renders in the
  current foreground color so it stays visible in both light and dark themes.
  `claude.svg` keeps its brand color, which reads on both.
- **Trademark:** the Claude/Anthropic and OpenAI marks are trademarks of their
  respective owners, used here **nominatively** — only to identify which agent a
  session belongs to. Not an endorsement; no modification of the marks beyond the
  `currentColor` tint above.

When the Xcode app target lands (PLAN U6), these move into the asset catalog (or
ship as bundle resources) and the badge view renders them at ~14pt.
