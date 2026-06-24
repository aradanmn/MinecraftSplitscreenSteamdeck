# Decision Log — 2026-06-19

## Session Context
A handoff prompt recommended ripping bwrap out of `launchSlot` for "Phase A",
claiming two compounding bugs. The user countered from memory that bwrap was
working before the window-positioning test. Goal: resolve the contradiction via
git history, fix the real bug, ship it.

## Key Decisions Made

### 1. Trust git history over the handoff's recommendation
**Decision:** Before acting on "rip out bwrap", trace when bwrap last worked.
**Why:** The user's recollection directly contradicted the handoff. git archaeology
is cheap and authoritative; throwing away a working sandbox design on a possibly
wrong diagnosis is expensive.
**Finding:** Working commit `d5f060c` did `--dev /dev` AND re-bound `/dev/dri`
(GPU), X11, fuse afterward. Phase A (`38c4f99`) rebuilt `launchSlot` from scratch
and dropped the GPU re-bind. The user was right.

### 2. Fix the regression, do NOT remove bwrap
**Decision:** Restore the working-era dev re-binds rather than launch PolyMC bare.
**Why:** bwrap is the controller-isolation mechanism (via `--bind /dev/null` masks).
Removing it would discard working isolation to "fix" a bug that is just a missing
bind line. The handoff's Bug #2 (SingleApplication / abstract sockets) was a
misdiagnosis — that forwarding worked fine in the d5f060c era with shared sockets.

### 3. Reject `--unshare-net`
**Decision:** Do not use per-slot network namespaces.
**Why:** Breaks internet (handoff acknowledged this) and is unnecessary — the
SingleApplication primary is supposed to launch all 4 JVMs. The only reason slots
appeared to "exit early" was the GPU bug killing the primary first.

### 4. Keep the two launchSlot copies in sync
**Decision:** Apply the identical change to `minecraftSplitscreen.sh` (prototype)
and `modules/launcher_script_generator.sh` (generator).
**Why:** The generator emits a standalone launcher that must behave identically to
the prototype; divergence here has bitten the project before.

### 5. Left the XDG_RUNTIME_DIR per-slot hack in place
**Decision:** Don't remove the Phase A `/tmp/polymc-runtime-slotN` isolation.
**Why:** It's a no-op for abstract sockets (harmless) and removing it adds churn /
risk for no benefit. Clean up later if desired.

### 6. Delegation model is inadequate; applied fix directly
**Decision:** After the delegated local model (`llama3.1:8b`) failed to produce a
valid tool call and fabricated success, applied the 4-line fix directly.
**Why:** A precise mechanical restore from known-good source isn't worth repeated
failed delegation cycles. **Action item:** repoint delegation at
`qwen2.5-coder:14b`.

## What We Know vs What We Assume

| Statement | Status | Source |
|-----------|--------|--------|
| `--dev /dev` overlays empty devtmpfs, hiding GPU nodes | **Known fact** | bwrap semantics + d5f060c re-bind proves intent |
| d5f060c bwrap worked (GPU re-bound) | **Known fact** | git show d5f060c:modules/instance_lifecycle.sh |
| Phase A dropped the /dev/dri re-bind | **Known fact** | git show 38c4f99 vs d5f060c |
| SingleApplication forwarding is the intended multi-instance path | **High confidence** | Worked in d5f060c with shared sockets |
| The fix makes 4 windows launch | **Unverified** | Needs Deck test (next step) |

## Commit
`d348bf1` — fix(bwrap): re-bind GPU/X11/shm/fuse after --dev /dev in launchSlot
