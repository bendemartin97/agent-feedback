---
name: feedback
description: Works through feedback items (screenshots with markup and a note) that the user assigned to this session or workspace with the agent-feedback app. Use when the user says "work through feedback", "process feedback", "go through the feedback", "look at the screenshots", "what's in the feedback", "feedback abarbeiten", or a prompt hook reports open feedback items.
---

# Work through feedback screenshots

With agent-feedback (menu bar app, default shortcut ⌃⌥S) the user captures one or more screen areas, marks them up (arrows, boxes, numbers ①②, text), assigns them to a session and optionally types a note. **An item is a `<time>.md`**; its images are listed in the frontmatter under `images:` (`<time>.png`, `<time>-2.png` …; empty = text-only task; old items without the line have exactly `<time>.png`). Items written before the switch to English use German keys and headings (`bilder:`, `fenster:`, `darstellung:`, `auftrag: sofort`, `## Ergebnis` …) – read them the same way, but write everything new in English. The `edit/` folder belongs to the app (originals and marks) – don't touch it. Reply in the user's language.

## Where it lives

```bash
~/.claude/agent-feedback/bin/feedback-dir.sh "${CLAUDE_PROJECT_DIR:-$PWD}"
```

- Workspace (if set up under `workspaces` in `~/.claude/agent-feedback/config.json`: `<workspaces>/<name>/…`) → `<workspaces>/<name>/feedback/`
- otherwise → `<project>/.feedback/` (contains a `.gitignore` with `*`)

Inside a workspace the workspace counts, otherwise the session's start directory. **Every item belongs to a session** (`session_id` in the `.md`); the prompt hook lists exactly your `.md` files with their images – use that list. If your task names exactly one `.md` ("only this item: …"), work on that one only. Without a hook list: all in `inbox/` whose `session_id` is missing, and ask about other sessions' items. Inside are `inbox/` (waiting for an agent or for the user's answer) and `done/` (implemented by the agent, the user reviews). If `inbox/` is empty or missing, say so and stop.

## Steps

1. **Read all open items**, oldest first: `ls <dir>/inbox/*.md`, read each `.md` and look at **every image from `images:`** with Read. Frontmatter:
   - `url`, `tab`: Chrome page (only if Chrome was in front) – tells you which page is meant
   - `window` (window size in points, ≈ viewport) and `appearance` (`light`/`dark`): important for layout and color bugs
   - `branch`: branches of the checkouts at capture time (in a workspace, all checkouts in it)
   - `image-1:`, `image-2:` … (only with several images): time, source, URL, tab and window size **per image** – if an item shows several pages or steps, the context of the respective image applies
   - `mode: now` means you run as your own agent without the user in the chat (see below)
   - **Blocks below the note** are the item's history: `## Result` (earlier agent runs), `## Answer` (the user's answer to a question), `## Rework` (what still isn't right after the user's visual review), `## Run failed`. The **most recent** answer or rework block is the current task; the note and earlier results are context.
2. **Briefly understand what is meant.** The `url` tells you which page (e.g. a local dev URL). Without a note, the image is the task: what looks broken, off or wrong? **Numbers in the image** (①②③) belong to the numbers in the note ("1 too far right") – each number is a sub-task. Several images of one item show the same thing (a flow, before/after).
3. **Make only the requested change.** Find the code, change exactly what the screenshot and note ask for – no tidying up around it, no side quests. **No review and no verify step**: no review or verify skills, no tests, no lint, no browser. The user checks the result themselves. If a stop hook still demands verification, reply briefly: "Feedback run: the user reviews visually, no verification wanted." The project's rules (CLAUDE.md) still apply, e.g. whether committing is allowed.
4. **Write the result into the `.md` right after each item** (not collected at the end). Append at the bottom; the user's note and the frontmatter stay unchanged:
   ```markdown
   ## Result <YYYY-MM-DD HH:MM>
   **Status:** implemented | nothing to do | open (question)
   **Cause:** <one sentence on why it looked like that>
   **Change:** <one or two sentences on what is different now>
   **Files:** `repo/path/file.vue:123`, …
   ```
   For `open (question)`, instead of Change/Files write a line `**Question:** <concrete question to the user>` – the app shows exactly this line in the answer dialog.
   - `implemented` and `nothing to do` (with the reason under Cause): move the `.md` and **all images from `images:`** to `<dir>/done/`. "Implemented" doesn't mean "finished": the user checks in the browser and accepts in the app ("Looks Good") or requests rework. **Never write an `## Accepted` block** – only the user does that.
   - `open (question)`: leave it in `inbox/`, put the `**Question:**` to the user. Don't guess. With `mode: now` (or the legacy `auftrag: sofort`) there is nobody to ask: only write the question into the `.md` and stop – the app shows the user ❓ in the menu bar.
   - After a rework or an answer, append another `## Result` block; never overwrite old blocks.

## Wrap-up

With `mode: now` (own agent): just one line of result, no report offer – the user sees the status in the menu bar.

Otherwise a table in the chat:

| Screenshot | Note | Change | Status |
|---|---|---|---|

Then offer in one line: "Shall I build a feedback report as an Artifact?" If the user wants it (or it was already part of the task, e.g. "with report"):

## Optional: report Artifact

A private Artifact (Artifact tool, load the `artifact-design` skill first), meant to be passed on to reviewers or for the ticket:
- Header: project/workspace, time span, counts implemented / accepted / nothing to do / open.
- One card per item: the screenshot (with the user's marks) as an embedded image, their note as a quote, below it Cause, Change, Files and a status badge. Open items first, with the question highlighted.
- Upload images as assets, or embed a few small ones as `data:` URIs (mind the 16 MB limit; shrink first with `sips -Z 1600`).
- The only source is the `## Result` blocks (or legacy `## Ergebnis` blocks) of the `.md` files in `done/` and `inbox/` from this run; don't invent anything.
- Give the link to the Artifact at the end of the chat.
