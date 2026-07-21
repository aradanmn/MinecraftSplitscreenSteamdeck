# Runbook — Back up the benchmark world, then test CurseForge BYOK on the Deck

*Point-in-time operator runbook for **PR #121** (branch `feat/curseforge-byok`,
issue #120). Print this and walk through it at the Deck. Created 2026-07-20.*

**Purpose.** (1) Preserve the weekend BENCH-AB baseline world so future benchmarks
compare apples-to-apples, then (2) test the new CurseForge bring-your-own-key (BYOK)
installer flow end-to-end before merging.

**How to use.** Every command runs in the Deck's **Konsole** (Desktop Mode) — or
Claude can run the non-interactive ones over `ssh steamdeck`. The **installer's own
prompts must be answered at the Deck**. Check each `[ ]` box as you go; record
PASS/FAIL where marked.

**Do Part 1 before anything else** — the installer can re-provision instances, and the
backup is the safety net for the benchmark world.

---

## Part 0 — Prereqs (2 min)

- [ ] Deck is in **Desktop Mode** (not a live Game-Mode session).
- [ ] Konsole open, or `ssh steamdeck` works from Claude's side.
- [ ] Note the current branch so we can return to it later:
  ```bash
  cd ~/MinecraftSplitscreenSteamdeck && git branch --show-current
  ```
  Expected: `main`. Write it here → __________

---

## Part 1 — Back up the benchmark world (DO FIRST)

### 1.1  Find the world
```bash
ls -la ~/.local/share/PolyMC/instances/latestUpdate-*/.minecraft/saves/
```
- [ ] Identify the benchmark world folder name(s). Write it here → __________
  (If each instance has its own copy, note which instance holds the canonical one —
  usually `latestUpdate-1`.)

### 1.2  Archive it (timestamped)
```bash
STAMP=$(date +%Y%m%d-%H%M%S)
BK=~/mcss-benchmark-world-$STAMP.tar.gz
tar czf "$BK" -C ~/.local/share/PolyMC/instances/latestUpdate-1/.minecraft saves
echo "wrote $BK"
```
- [ ] Command completes with no error.

### 1.3  Verify the archive
```bash
tar tzf "$BK" | head
ls -lh "$BK"
sha256sum "$BK"
```
- [ ] Listing shows `saves/<worldname>/...`; size is non-trivial (MBs). Record the
  sha256 → __________________________

### 1.4  Copy it OFF the Deck (durability)
The Deck is one SD-card failure from losing this. Pull a copy off-device:
```bash
# From Claude's side (LXC), or any second machine:
scp steamdeck:"$BK" ~/benchmark-baselines/     # create the dir first if needed
```
- [ ] A second copy now exists off the Deck. Off-Deck path → __________
- [ ] **Label it** clearly as the BENCH-AB baseline (this is the world the weekend 4P
  numbers — ~42% CPU capped @60 vs 92–94% uncapped — were measured on).

> **Gate:** do not proceed until the backup exists in **two** places.

---

## Part 2 — Put the BYOK branch on the Deck

### 2.1  Check out the branch
```bash
cd ~/MinecraftSplitscreenSteamdeck
git fetch origin
git checkout feat/curseforge-byok
git pull --ff-only
git log --oneline -1        # expect: feat(#120): CurseForge bring-your-own-key ...
```
- [ ] HEAD is the BYOK commit.

### 2.2  Confirm the branch code is what will run
```bash
grep -n "resolve_curseforge_api_token" modules/utilities.sh | head
```
- [ ] Shows the new function (proves the checkout has the BYOK code).

### 2.3  Decide the test target (avoid clobbering the real instances)
Prefer installing into a **throwaway directory** so the benchmark instances aren't
touched. First check whether the installer accepts a target override:
```bash
grep -nE "TARGET_DIR=|MCSS_TARGET_DIR" install-minecraft-splitscreen.sh | head
./install-minecraft-splitscreen.sh --help 2>&1 | head -30
```
- [ ] If a target override exists → use `TARGET_DIR=/tmp/byok-test` on every install
  command below.
- [ ] If not → the Part 1 backup is your safety net; the installer's update/preserve
  path should keep the world, but the backup is why we did it first.

---

## Part 3 — Test the BYOK flow (5 scenarios)

For each install run, the prompt only appears when you **add a custom CurseForge mod**
(default mods are all Modrinth). At the "add custom mods?" step answer **y**, then
paste **any CurseForge numeric project ID** (from a curseforge.com mod-page URL, e.g.
`394468`). We're testing the *key prompt behavior*, not whether that specific mod
resolves.

> **Save time:** mod selection happens early, before the heavy Minecraft
> download/provision phase. For Tests **A, C, D** you can **Ctrl-C** right after you've
> observed the prompt behavior — you don't need to finish the install. Only **Test B**
> (prompt → save → no re-prompt → key file written) and **Test E** (piped, must run to
> completion to prove no-hang) need to run through. That's effectively **one** full
> install, not five.

Key file location (created when you enter a real key):
`~/.config/minecraft-splitscreen/curseforge-api-key`

### Test A — Env var wins (no prompt)   [must pass]
```bash
rm -f ~/.config/minecraft-splitscreen/curseforge-api-key      # ensure no saved key
CURSEFORGE_API_KEY="test-not-a-real-key" ./install-minecraft-splitscreen.sh
# → add custom mods? y → paste a CurseForge ID
```
- [ ] **No key prompt appears** (the env var short-circuits it). → **PASS / FAIL**

### Test B — Interactive prompt + save + no re-prompt   [must pass — the core test]
```bash
rm -f ~/.config/minecraft-splitscreen/curseforge-api-key
unset CURSEFORGE_API_KEY
./install-minecraft-splitscreen.sh
# → add custom mods? y → paste a CurseForge ID
```
- [ ] A prompt appears: *"CurseForge API key (Enter to skip):"* with the explanatory
  lines above it. → **PASS / FAIL**
- [ ] Enter a **real** CurseForge key. Then, when asked for another mod, paste a
  **second** CurseForge ID.
- [ ] **No second prompt** — the key is remembered. → **PASS / FAIL**  *(this is the
  #1 bug the old WIP had)*
- [ ] Key file now exists, perms `-rw-------`:
  ```bash
  ls -l ~/.config/minecraft-splitscreen/curseforge-api-key
  ```
  → **PASS / FAIL**

### Test C — Skip with Enter (declared, not silent)   [must pass]
```bash
rm -f ~/.config/minecraft-splitscreen/curseforge-api-key
unset CURSEFORGE_API_KEY
./install-minecraft-splitscreen.sh
# → add custom mods? y → paste a CurseForge ID → at the key prompt press ENTER
```
- [ ] A clear message states CurseForge mods will be **skipped** and Modrinth mods are
  unaffected (not a silent skip). → **PASS / FAIL**
- [ ] The install **continues** and Modrinth mods still install. → **PASS / FAIL**

### Test D — Saved key file is reused (no prompt)   [should pass]
(Run right after Test B, which saved a key.)
```bash
unset CURSEFORGE_API_KEY      # rely on the saved file
./install-minecraft-splitscreen.sh
# → add custom mods? y → paste a CurseForge ID
```
- [ ] **No prompt** — key read from the file. → **PASS / FAIL**

### Test E — Unattended / piped, NO HANG   [must pass — the other WIP bug]
```bash
rm -f ~/.config/minecraft-splitscreen/curseforge-api-key
unset CURSEFORGE_API_KEY
printf 'y\n394468\ndone\n' | ./install-minecraft-splitscreen.sh
```
- [ ] The installer **does not hang** waiting for a key; it prints the skip
  declaration and **completes**. → **PASS / FAIL**
  *(The old WIP read `/dev/tty` here and hung invisibly.)*

---

## Part 4 — Restore & clean up

- [ ] Remove the test key file if you don't want it kept:
  ```bash
  rm -f ~/.config/minecraft-splitscreen/curseforge-api-key
  ```
- [ ] If you tested into the **real** target (not a throwaway) and the benchmark world
  looks changed, restore it:
  ```bash
  tar xzf ~/mcss-benchmark-world-<STAMP>.tar.gz \
      -C ~/.local/share/PolyMC/instances/latestUpdate-1/.minecraft
  ```
- [ ] Return the checkout to `main`:
  ```bash
  cd ~/MinecraftSplitscreenSteamdeck
  git checkout main && git pull --ff-only && ./deploy.sh
  ```
- [ ] Confirm the benchmark-world backup (both copies) is still safe.

---

## Part 5 — Report / next

- [ ] Report the PASS/FAIL for Tests **A, B, C, E** (the must-pass set).
- [ ] If all green → Claude completes the closeout: **merge PR #121 → delete
  `wip/curseforge-byok` → close #120 → note #33**.
- [ ] If anything fails → paste the terminal output; Claude fixes on the branch and we
  re-run the affected test only.

---

## Quick reference

| Thing | Value |
|-------|-------|
| Branch under test | `feat/curseforge-byok` (PR #121) |
| Installer entry | `~/MinecraftSplitscreenSteamdeck/install-minecraft-splitscreen.sh` |
| Key file | `~/.config/minecraft-splitscreen/curseforge-api-key` |
| Env override | `CURSEFORGE_API_KEY` (a real key wins) · `CURSEFORGE_KEY_FILE` (path) |
| Benchmark world | `~/.local/share/PolyMC/instances/latestUpdate-1/.minecraft/saves/<world>` |
| World backup | `~/mcss-benchmark-world-<STAMP>.tar.gz` (+ off-Deck copy) |
| CF test mod ID | any curseforge.com numeric project ID (e.g. `394468`) |
