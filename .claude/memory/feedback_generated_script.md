---
name: Generated script vs generator source out of sync
description: The generated minecraftSplitscreen.sh has been manually enhanced beyond what launcher_script_generator.sh produces
type: feedback
---

The generated `minecraftSplitscreen.sh` (in PrismLauncher's data dir) has historically been
manually edited to add features that were never back-ported to `launcher_script_generator.sh`.

**Why:** Features get tested directly in the generated script, then sometimes forgotten in the source.

**How to apply:** When fixing bugs or adding features:
1. Fix the generated script first for immediate testing
2. Always back-port the same changes to the heredoc section of `launcher_script_generator.sh`
3. Verify with `grep` that the function exists in BOTH files before committing
4. The heredoc runs from line ~96 to ~2070+ of the generator; functions inside are what gets generated
