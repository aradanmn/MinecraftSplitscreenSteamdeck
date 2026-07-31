# Audit — #98 code-level style gaps

> #98a, 2026-07-31. Deliverable is this list; **no code changed**. Fixes are #98b,
> scheduled in v1.2.3 *after* v1.2.2 lands.
>
> **Audited against the post-v1.2.2 module set** (branch `refactor/91-pr-c`), not
> `main`. Auditing `main` would have covered `lwjgl_management.sh`,
> `steam_integration.sh` and `desktop_launcher.sh` — all deleted or merged by the
> pending stack — and missed `runtime_deploy.sh`, `system_integration.sh` and
> `version_stamp.sh`. That ordering is the whole reason the 2026-07-17 audit put
> the merges before the retrofit.

## Headline: one of the three "style gaps" is a live correctness bug

Item 2 turned out not to be cosmetic. See [Item 2](#item-2--print_-helpers-write-to-stdout).

---

## Item 1 — strict mode (`set -euo pipefail`)

The issue names `kwin_positioner.sh` and `minecraftSplitscreen.sh`. The real
picture is a clean split, and the fix is smaller than "13 files are missing it".

| Group | Strict mode | Files |
|---|---|---|
| Entry scripts | **yes** | `install-minecraft-splitscreen.sh`, `deploy.sh`, `uninstall-minecraft-splitscreen.sh` |
| Entry scripts | **NO** | `minecraftSplitscreen.sh` |
| Runtime modules | **yes** | `controller_monitor`, `controller_proxy`, `dex`, `dock_detection`, `instance_lifecycle`, `orchestrator`, `slot_manager`, `watchdog`, `window_manager` |
| Runtime modules | **NO** | `kwin_positioner`, `preflight`, `runtime_context` |
| Installer modules | **NO** (all) | `evsieve_management`, `instance_creation`, `java_management`, `launcher_setup`, `main_workflow`, `mod_management`, `runtime_deploy`, `system_integration`, `utilities`, `version_management`, `version_stamp` |

**Sourced modules inherit strict mode from the entry script**, so the installer
modules are already running under `set -euo pipefail` via
`install-minecraft-splitscreen.sh`. Adding it to each would be redundant, and
actively harmful for any module also sourced by something that does not want `-e`.

**The finding worth acting on:** `minecraftSplitscreen.sh` has no strict mode of its
own, but **acquires it as a side effect partway through its module source loop** —
verified empirically (sourcing a strict module flips the shell from `hBc` to
`ehuBc`). Manifest order:

```
1. preflight.sh          -            <- launcher runs UNSTRICT here
2. runtime_context.sh    -            <- and here
3. dock_detection.sh     SETS strict  <- strict mode silently begins
4..12                    (mostly set) 
```

So the launcher's first two module sources — including `runtime_context.sh`, which
resolves every path and constant the session depends on — run without `-e`/`-u`,
and everything after runs with them. Nothing declares this; it is an accident of
manifest order that would change if the manifest were reordered.

**Recommended fix (#98b-1):** declare `set -euo pipefail` explicitly at the top of
`minecraftSplitscreen.sh` and `kwin_positioner.sh`, and leave the sourced installer
modules alone with a one-line note in STYLE-GUIDE §7.1 recording *why* (inheritance,
not oversight). Risk: the launcher's first two sources currently tolerate failures
they would no longer tolerate — that is exactly the behaviour change to validate on
a real launch, not just in CI.

---

## Item 2 — `print_*` helpers write to stdout

`utilities.sh`: `print_header`, `print_success`, `print_warning`, `print_info`,
`print_progress`, `print_debug` all `echo` to **stdout**. Only `print_error`
redirects to stderr.

The issue says "audit call sites before flipping streams: some may capture the
output". Doing that audit found two functions whose stdout is captured *and* which
call `print_*`:

### `get_supported_minecraft_versions` — already safe

All 8 of its `print_*` calls carry an explicit `>&2`. The author worked around the
stdout-printing helpers by hand. It is correct today.

### `handle_instance_update` — **BROKEN TODAY**

`modules/instance_creation.sh`. Fifteen `print_*` calls, **none** redirected. Its
stdout is captured:

```bash
preserve_options_txt=$(handle_instance_update "$instances_dir/$instance_name" "$instance_name")
```

The function intends to return `"true"` or `"false"`. What the caller actually gets
is every progress line **plus** the value:

```
[💡 Updating existing instance: latestUpdate-1
🔄 Clearing old mods...
✅ Old mods cleared
true]
```

That value is passed to `install_fabric_and_mods` as `$3`, which tests
`[[ "$preserve_options" == "true" ]]`. A multi-line blob is not equal to `true`, so
the test fails.

**Impact: `options.txt` preservation is silently disabled on the instance-update
path.** A user updating an existing instance to a new Minecraft version loses their
video settings and keybinds, despite code written to preserve them. It fails
silently — no error, no warning.

**Filed as #167**, ahead of the style work: it is a behaviour bug that happens to
have been found by a style audit.

**Recommended fix (#98b-2):** flip the six helpers to `>&2` in `utilities.sh`. That
fixes `handle_instance_update` as a side effect, makes the 8 hand-written `>&2` in
`get_supported_minecraft_versions` redundant (harmless — leave or clean up), and
removes the trap for the next author who writes a data-returning function and
forgets. Installer UX text belongs on stderr under the project's own
stdout-is-data rule (STYLE-GUIDE §7.10) regardless.

**Risk to check before flipping:** anything that captures installer output
wholesale — CI, `test_installer.sh`, or a user piping the installer — would see UX
text move streams. Worth one grep pass over the test suite in #98b.

---

## Item 3 — `[dex]` prefix on stderr

`dex.sh` is a bash wrapper around an embedded Python backend, so this splits:

| Side | stderr messages | missing `[dex]` |
|---|---|---|
| bash | 1 | 1 (`dex_search` usage, line 547) |
| python | 5 | 5 (`Cannot open display`, usage, actions list, bad-args, unknown-action) |

Six lines total. Purely cosmetic, no capture risk, no behaviour change — the only
one of the three items that is genuinely just style.

**Recommended fix (#98b-3):** prefix all six. Trivial.

---

## Suggested order for #98b

1. **The `handle_instance_update` bug (#167)** — separately, first, as a bug fix
   rather than a style change. Needs a real install-update run to validate (v1.2.2's run
   could cover it if the instance path is exercised).
2. **`print_*` → stderr** — the systemic fix, after the grep pass over test call
   sites.
3. **Strict mode on the two entry/runtime files** — needs a real launch to validate.
4. **`[dex]` prefixes** — trivial, no validation beyond CI.

Items 1–3 all touch executable lines and need Deck validation. Item 4 does not.
