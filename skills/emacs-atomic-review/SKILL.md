---
name: emacs-atomic-review
description: Atomic review (原子审查) of a branch or MR in the user's Emacs. Split the branch's committed changes into items of one intent each, show them in an Emacs review buffer where the user annotates lines, and answer the annotations. Use when the user asks for an atomic review ("展开 atomic review", "做个原子审查", "atomic review this branch"), or when a message starts with [原子审查·标注].
---

# Atomic review in Emacs

You plan the review; Emacs does the rest through the emacs MCP tools
`review_snapshot`, `review_build`, `review_comments` and `review_reply`.
Emacs pins the diff, checks that your plan covers every changed line exactly
once, and shows the review in a buffer next to this session. No other model
is involved: understand the code yourself.

## Make a review

1. **Choose the comparison.** Only committed changes are compared, never
   uncommitted files. For "against main", check whether local `main` or
   `origin/main` is meant; fetch first when the remote one is. Ask when the
   branch to review is unclear.
   A single commit is base `<commit>^`, head `<commit>`; a range `A..B` is
   base `A`, head `B`.
2. **Pin it** with `review_snapshot` (base, head). It returns the merge base,
   the head commit and every file's hunks. When the user's message says Emacs
   already pinned a snapshot (the `/atomic-review` command), skip step 1 and
   call `review_snapshot` with only that `snapshot` id. Small diffs come with the hunks'
   text (`fragments`); for large ones run the returned `diff_command`
   yourself.
3. **Read the code.** Read the hunks and, around them, the sources at the
   pinned head (`git show <head_sha>:<path>`; the worktree may be at another
   commit). The intents you write must come from the code, not from commit
   messages alone.
4. **Split by intent.** One item per independent intent:
   - foundations and core logic first, then their call sites, then tests;
   - related tests may form an item of their own; upstream test corpora are
     grouped by case or package;
   - never group by an arbitrary number of lines, and never pack unrelated
     abilities into one big item;
   - a large new file is split along declarations, functions or test cases.
5. **Build it** with `review_build`: the snapshot id, a summary and the items
   (format below). When it reports a coverage error, fix the plan; never drop
   changes that are hard to place.
6. **Hand it over.** Tell the user the base and head, the number of items and
   anything notable, in a few lines. They read it in Emacs: selecting lines
   and pressing `a` writes an annotation that is sent to this session.

The split is a static reading of the diff: never describe it as compiled or
tested.

### Writing the plan

Write titles, intents and the summary in Chinese.

- **summary**: the overview at the top of the review, for the whole compared
  change (not one commit or item): the problem it solves, behavior before and
  after, user-visible effects, the main risks if any. A few sentences; don't
  repeat the items.
- **item**: `{"title", "intent", "type", "parts"}`.
  - `intent` explains, from the source, why the change is made and the
    inputs, outputs and edge cases of the functions it touches.
  - `type`: 0 formatting, 1 refactoring, 2 feature, 3 local fix, 5 tests.
  - each part names a file of the snapshot and selects exactly one of:
    - `"hunks": [0, 2]`: zero-based hunk indexes within that file, as listed
      by `review_snapshot`;
    - `"whole": true`: all its hunks, or a binary or metadata-only file;
    - `"added_lines": [10, 45]`: an inclusive line range of a newly added
      text file only. Assign its headers, imports and blank lines too.

Example item:

```json
{"title": "保留调用实参中的命名类型",
 "intent": "…",
 "type": 3,
 "parts": [{"file": "compiler/typeck/src/call.rs", "hunks": [0, 3]}]}
```

### Updating a review

When the branch has moved, pin a new snapshot and build a new plan; the old
review keeps its annotations. You may reuse descriptions of unchanged parts,
but take hunk indexes from the new snapshot. Building the same plan again
reopens the existing review.

## Answer annotations

Each annotation arrives as a user message starting with `[原子审查·标注]`.
It carries the item, file, line range (新: lines at head, 旧: lines at the
merge base), the selected code, the user's text, and the review id,
annotation id and revision.

- Treat it as the user's review comment. Check it against the pinned
  commits, not the current worktree.
- Answer only by calling `review_reply` with that revision. The answer shows
  under the annotation in the review; don't also write it in the
  conversation (at most one line saying you replied).
- A revision conflict means the user edited the annotation after you read it:
  read it again with `review_comments` and answer the new text.
- Use status `resolved` only when the issue is actually fixed or the user
  asks; otherwise the default, `responded`.
- Answering is not permission to change the code. Change it only when the
  user asks.
- Don't wait or poll for annotations; they come to you as messages.
  `review_comments` re-reads them, for example after a restart.
