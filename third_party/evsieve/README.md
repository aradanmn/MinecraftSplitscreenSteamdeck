# `third_party/evsieve/` — GPL-2.0 island

This directory is a self-contained GPL-2.0 island inside MCSS. It vendors
**only our patch**, never upstream evsieve source (#38 D4/PR1).

## Upstream

- Project: [`github.com/KarsMulder/evsieve`](
  https://github.com/KarsMulder/evsieve)
- Pinned commit: `ebd7efe1ee902e70c5943b65a2bf44b9a3c31eb8`
  (= v1.4.0 + master fixes)
- License: GPL-2.0 (see `COPYING` in this directory, copied verbatim
  from upstream's `LICENSE` file at the pinned commit)

## Why build-at-install

MCSS never redistributes an evsieve binary. `modules/evsieve_management.sh`
clones the pinned upstream commit, applies the patch below, and compiles
it on the user's own machine (DESIGN-38 D4). This is the cleanest GPL
posture available: we distribute source, the user's machine produces the
binary, and there is no "offer to provide source" obligation to track —
the same model this repo already uses for JDK acquisition
(`modules/java_management.sh`), minus the redistribution.

## Reproducible pin

Anyone can verify the acquired source matches exactly what MCSS built
against:

```bash
git clone https://github.com/KarsMulder/evsieve.git
git -C evsieve checkout ebd7efe1ee902e70c5943b65a2bf44b9a3c31eb8
git -C evsieve rev-parse HEAD
# must print: ebd7efe1ee902e70c5943b65a2bf44b9a3c31eb8

git -C evsieve archive --format=tar ebd7efe1ee902e70c5943b65a2bf44b9a3c31eb8 \
    | sha256sum
# must print: 118fb0e33d11a4de54621c7d5c562e98f9b00ac07d01a1d7aa9de4951a1bc86d
```

`git archive` output is a deterministic byte stream (unlike GitHub's
codeload tarballs, which are gzip-layer nondeterministic — see the 2023
checksum-breakage incident), so this reproduces identically on any
machine, and is why the pin is verified this way rather than against a
downloaded-tarball SHA.

## Patch rationale

`evsieve-persist-reopen.patch` (~35 lines, SHA-256
`9ec2cd9d50e0ed1eb387379d5baacadd565861c84fa1bbe8a4f800c8db261154`) fixes
a first-`EACCES` blueprint drop in `src/persist/subsystem.rs`: the
`try_open` path drops a blueprint on the FIRST `EACCES` while udev is
still applying the uaccess ACL on a Bluetooth controller reconnect —
upstream evsieve issue #66. Our fix converts that immediate drop into a
bounded retry (`MAX_ERROR_RETRIES = 60`), giving roughly one second of
recovery instead of a permanent loss of the reconnecting device. This
patch is itself a derivative work of evsieve and is therefore GPL-2.0,
same as upstream.

## Aggregation stance

MCSS invokes the built `evsieve` binary as a separate process (arm's
length `exec`, no linking). This is mere aggregation under GPL-2.0: the
license obligation covers only the evsieve component in this directory
and does not propagate to the rest of MCSS.

## #33 pointer

This island means the repo now carries mixed licensing (this GPL-2.0
island alongside the installer's own not-yet-resolved top-level license).
Flag this directory for the top-level LICENSING note tracked in #33,
which is meant to enumerate every such island.
