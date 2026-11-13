# Master content cleanup — 2026-11-13

This pass removes prohibited game material from master and its reachable
history under the repository policy in `AGENTS.md`. It prepares the source
for code review. Runtime repair and README presentation are separate work.

The removal list is [copyright-cleanup-paths.txt](copyright-cleanup-paths.txt).
It covers extracted item icons, generated quest/item/road/spawn tables,
recorded route datasets, captured frames and their summaries, a
screenshot-derived reference, and capture fixtures without established
synthetic provenance. Every nonempty historical blob at those paths was
also excluded by object ID, removing exact copies under other names.

Our source, generators, documentation, small authored policy constants, and
synthetic tests remain. Pending source edits from the original master
checkout were preserved; the pending generated quest-data edit was excluded.
Deleted data may still be referenced by code and tests. This cleanup does
not establish that the project currently builds or runs.

The original master was `f40954cc5cb11fadf327a3f4317bf6886284f7e8`.
The rewritten base, before this cleanup record and pending source edits,
is `0d357c7b3ef7d5cec1891c81da96eee42a980433`.

An independent private archive lives at `../shadow-copyrighted`. Its
`.copyright-cleanup/` directory holds the original refs, pending patches,
worktree snapshots, excluded blob IDs, commit mapping, audit program, and
validation records. The archive contains prohibited material and must never
be published. Runtime symlinks still reference the original external data.

Only Gitea master is rewritten. Other branches, the stash, linked worktrees,
and existing local objects still retain original history. They have not been
scrubbed. Do not merge that history into cleaned master; future migrations
must replay reviewed source changes without reintroducing excluded content.
Future GitHub publication must use a fresh master-only clone and push only
`refs/heads/master`; never mirror-push the original repository.

Source licensing is maintained separately in [LICENSE](../LICENSE). The
repository policy does not grant rights to third-party game content.

## How to regenerate the verification

From a fresh master-only clone, with access to the private archive:

```sh
cleanup=/home/monofuel/src/wow-coworld/shadow-copyrighted/.copyright-cleanup
nim r --hints:off "$cleanup/audit_master.nim" "$PWD" \
  docs/copyright-cleanup-paths.txt "$cleanup/remove-blob-ids.txt" verify
git fsck --full --strict
git log master --format= --name-only | sort -u
git rev-list --objects master
git status --short
```

The audit checks every reachable historical path and blob against the
removal manifests and rejects any surviving binary blob. It was also run
against the original history as a negative control, which must fail.
