# ZMK Eyelash Corne — Problems & Solutions

A detailed engineering log of the issues hit while adding and building the
`eyelash_corne_touchpad` variant with `prepare_zmk_build_environment.sh` and
`build_urob_zmk.sh`, including root-cause analysis and the exact fixes applied.

> **TL;DR** — The eyelash_corne boards only build on **Zephyr `v3.5.0+zmk-fixes`
> + Python 3.9**. The repo's west manifest tracked *moving* upstream branches, so
> a fresh `west update` pulled **Zephyr 4.1**, which (a) demanded Python ≥ 3.10
> and (b) broke with the new Zephyr board model (`Kconfig.defconfig not found`).
> A third, latent bug — CMake resolving the *wrong* workspace's Zephyr from the
> shared package registry — was exposed along the way. Fixes: pin the manifest to
> known-good commits, default the venv to Python 3.9 (with a `--python`
> override), and export `ZEPHYR_BASE` in the build script.

---

## Table of contents

- [Context & environment](#context--environment)
- [Goal](#goal)
- [Timeline of symptoms](#timeline-of-symptoms)
- [Problem 1 — Python version mismatch (Zephyr needs ≥ 3.10)](#problem-1--python-version-mismatch-zephyr-needs--310)
- [Problem 2 — CMake resolves the wrong Zephyr (package-registry contamination)](#problem-2--cmake-resolves-the-wrong-zephyr-package-registry-contamination)
- [Problem 3 — `Kconfig/soc/Kconfig.defconfig not found` (root cause)](#problem-3--kconfigsockconfigdefconfig-not-found-root-cause)
- [Problem 4 — automation gotcha: `z: command not found` / `BASH_ENV`](#problem-4--automation-gotcha-z-command-not-found--bash_env)
- [The complete fix, file by file](#the-complete-fix-file-by-file)
- [Verification](#verification)
- [Known-good reference stack](#known-good-reference-stack)
- [Lessons & prevention](#lessons--prevention)

---

## Context & environment

- **Host:** Linux, builds run **locally** (no Docker) via
  `from-urob-zmk-config/scripts/zmk_build.sh -l`.
- **Zephyr SDK:** `~/zephyr_sdk/` (0.16.3 / 0.15.0 present).
- **Pythons available:** `python3.9` (3.9.25) and `python3.12` (3.12.3) — *no*
  3.10/3.11.
- **Config repo:** `git@github.com:techcaotri/from-urob-zmk-config.git`, one
  branch per keyboard variant.
- **New workspace:** `…/Eyelash-Corne-Touchpad/source_urob_zmk_eyelash_corne_touchpad`.
- **Reference (known-good) workspace:** `…/Sources/source_urob_zmk_eyelash_corne`
  (last built successfully in June 2025).

## Goal

1. Create branch `eyelash_corne_touchpad` from `eyelash_corne`.
2. Teach the scripts to prepare the new variant into an arbitrary `-p` path.
3. Build it locally and produce correct firmware.

A fresh prepare + build of the new branch failed, even though the branch content
was identical to `eyelash_corne` (same tip `2b7a94a`). That contradiction is the
thread that unraveled all three real problems.

---

## Timeline of symptoms

1. First build → **`Could NOT find Python3 … required is at least "3.10"`**.
2. After switching the venv to Python 3.12 → **`CMake Error … kconfig.cmake:396`**
   → underlying **`Kconfig/soc/Kconfig.defconfig not found`**.
3. While reading the first failure's stack trace, noticed CMake was including
   `ZephyrConfig.cmake` from a **different workspace** than the one being built.

These are three distinct problems with one shared upstream cause (a floating
manifest pulling Zephyr 4.x). They are documented separately because each needed
its own fix and each can recur independently.

---

## Problem 1 — Python version mismatch (Zephyr needs ≥ 3.10)

### Symptom

```text
CMake Error at /usr/share/cmake-3.28/Modules/FindPackageHandleStandardArgs.cmake:230 (message):
  Could NOT find Python3: Found unsuitable version "3.9.25", but required is
  at least "3.10" (found .../.venv/bin/python3.9, found components: Interpreter)
Call Stack (most recent call first):
  …/zephyr/cmake/modules/python.cmake:43 (find_package)
```

### Investigation

- `prepare_zmk_build_environment.sh` hard-coded the interpreter:
  `python3.9 -m venv .venv`.
- The build log printed `zephyr_version: 410` — i.e. **Zephyr 4.1.0**, which
  raised Zephyr's minimum Python from 3.8 to **3.10**.
- This was surprising: the *same branch* used to build fine on Python 3.9. That
  meant the Zephyr version had changed underneath us (foreshadowing Problem 3).

### Root cause

The venv interpreter was fixed at 3.9, but the Zephyr that `west update` fetched
now requires ≥ 3.10. The interpreter choice and the Zephyr version are coupled,
and the script offered no way to pick a different Python.

### Solution

Made the interpreter selectable and auto-detected in
`prepare_zmk_build_environment.sh`:

- New `-y` / `--python` option.
- `check_python_venv` resolves an interpreter in this order when `--python`
  isn't given: `python3.9 → python3.10 → python3.11 → python3.12 → python3`.
- **Default stays `python3.9`** on purpose — see Problem 3; the final, correct
  stack is Zephyr 3.5, which is validated on 3.9 (and breaks on 3.12 where
  `distutils` was removed). For an intentional Zephyr 4.x build, run
  `--python python3.12`.

```bash
local py="$python_bin"
if [[ -z "$py" ]]; then
    for candidate in python3.9 python3.10 python3.11 python3.12 python3; do
        command -v "$candidate" &>/dev/null && { py="$candidate"; break; }
    done
fi
"$py" -m venv .venv
```

> **Note:** switching to Python 3.12 made this specific error disappear but
> exposed Problem 3 — proof that 3.10+ alone does not make these boards build.

---

## Problem 2 — CMake resolves the wrong Zephyr (package-registry contamination)

### Symptom

In the Python-3.9 failure's stack trace, the `ZephyrConfig.cmake` being included
came from a **different workspace** than the one under build:

```text
Call Stack (most recent call first):
  …/source_urob_zmk_eyelash_corne_touchpad/zephyr/cmake/modules/python.cmake:43
  …
  /home/tripham/Dev/Kinesis_Adv360_Pro/Sources/source_urob_zmk_eyelash_corne/zephyr/share/zephyr-package/cmake/ZephyrConfig.cmake:66
                                  ^^^^^^^^^^^^^^^^^^^^^^^^^^^^ the OLD workspace, not the touchpad one
```

### Investigation

- ZMK's `zmk/app/CMakeLists.txt` line 9 is:
  `find_package(Zephyr REQUIRED HINTS ../zephyr)`.
- In a west workspace the app lives at `zmk/app`, so `../zephyr` resolves to
  `zmk/zephyr` — **which does not exist** (Zephyr is at the *workspace* root,
  `…/zephyr`). The `HINTS` therefore miss, and CMake falls back to the **user
  package registry** at `~/.cmake/packages/Zephyr`.
- That registry accumulates **one entry per `west zephyr-export` ever run**. It
  contained five Zephyr installations:

  ```text
  ~/.cmake/packages/Zephyr/* ->
    …/Eyelash-Corne-Touchpad/source_urob_zmk_eyelash_corne_touchpad/zephyr/share/zephyr-package/cmake
    …/zmk-config/zephyr/share/zephyr-package/cmake
    …/source_urob_zmk_eyelash_corne_dongle/zephyr/share/zephyr-package/cmake
    …/source_urob_zmk_eyelash_corne/zephyr/share/zephyr-package/cmake      ← got picked
    …/source_urob_zmk_adv360-pro/zephyr/share/zephyr-package/cmake
  ```

- With multiple registered Zephyrs and no version constraint, CMake's choice is
  effectively unspecified — here it picked `source_urob_zmk_eyelash_corne`'s
  Zephyr instead of the touchpad workspace's.

### Root cause

The shared, append-only CMake user package registry plus a non-resolving
`HINTS ../zephyr` means a multi-workspace machine can build a variant against the
**wrong Zephyr tree**. This is latent and only becomes visible when the wrong
tree differs in a way that breaks (e.g. a Python-version check, or a different
Zephyr major version).

### Solution

Export `ZEPHYR_BASE` to the workspace's own Zephyr in `build_urob_zmk.sh`.
Zephyr's `ZephyrConfigVersion.cmake` treats every registered package whose path
≠ `$ENV{ZEPHYR_BASE}` as *unsuitable*, so the registry can only resolve to the
intended tree:

```bash
ZEPHYR_DIR="$SOURCE_DIR/zephyr"
export ZEPHYR_BASE="$ZEPHYR_DIR"
```

This is robust for **all** variants, not just the touchpad, and requires no
cleanup of the registry.

> Alternative considered: deleting stale `~/.cmake/packages/Zephyr/*` entries.
> Rejected — it's a manual, recurring chore and doesn't survive the next
> `west zephyr-export`. Pinning `ZEPHYR_BASE` is deterministic.

---

## Problem 3 — `Kconfig/soc/Kconfig.defconfig not found` (root cause)

### Symptom

After fixing Python (3.12) and Zephyr selection (`ZEPHYR_BASE`), configure still
failed for every board:

```text
…/zephyr/scripts/kconfig/kconfig.py: Kconfig.zephyr:29:
  '…/build/eyelash_corne_left_nice_epaper_3.2/Kconfig/soc/Kconfig.defconfig'
  not found (in 'source "$(KCONFIG_BINARY_DIR)/soc/Kconfig.defconfig"').
CMake Error at …/zephyr/cmake/modules/kconfig.cmake:396 (message):
  command failed with return code: 1
```

### Investigation

The new branch was identical to `eyelash_corne` (`2b7a94a`), yet the reference
workspace built and the new one didn't. The only possible difference was the
*dependencies* `west update` pulled. Comparing the two workspaces:

| Project | Known-good (`source_urob_zmk_eyelash_corne`) | Fresh touchpad workspace |
| --- | --- | --- |
| Zephyr | **3.5.0** (`0fa4cc26`, 2025-02-01) | **4.1.0** (`58a5874a`, 2026-03-20) |
| ZMK | `6f85f48b` (2025-04-04) | `64daf698` (2026-06-20) |

Then the manifest, `from-urob-zmk-config/config/west.yml` — **identical** in both
workspaces, and it tracks moving branches:

```yaml
- name: zmk
  remote: zmkfirmware
  revision: main          # ← floating
  import: app/west.yml    # ← ZMK's own west.yml chooses Zephyr
- name: zmk-helpers
  revision: main          # ← floating
- name: zmk-tri-state
  revision: main          # ← floating
- name: mario-peripheral-animation
  revision: main          # ← floating
- name: zmk-nice-oled
  revision: add_nice_epaper_new
```

ZMK's `zmk/app/west.yml` is what pins Zephyr. In the **April-2025 ZMK** it was
`revision: v3.5.0+zmk-fixes`; today's `main` bumped it to Zephyr 4.x.

### Root cause

The manifest pins `zmk` (and the helper modules) to **moving branches**. The
reference workspace ran `west update` in early 2025 and captured Zephyr 3.5; the
fresh workspace ran it in 2026 and captured Zephyr 4.1. The **urob/eyelash_corne
board uses the legacy Zephyr board model**; Zephyr 4.x's HWMv2 generates the
SoC Kconfig tree differently and the board's wiring no longer produces
`Kconfig/soc/Kconfig.defconfig` → configure aborts. Same source, different
"floating" dependencies = non-reproducible build.

### Solution

Pin the variant's manifest to the **exact known-good commit set** taken from the
reference workspace, so `west update` always reconstructs Zephyr 3.5:

```yaml
- name: zmk
  remote: zmkfirmware
  revision: 6f85f48b19afae04f98e9abacb36ce1425b61f78   # imports Zephyr v3.5.0+zmk-fixes
  import: app/west.yml
- name: zmk-helpers
  revision: 8d7e79731803c961bae61f6fc8ffa3a35a62e5eb
- name: zmk-tri-state
  revision: ebbc1f0ccdb51669650bb0ac3e34920d09e62400
- name: mario-peripheral-animation
  revision: 1aa3950d6c86b4240b3f79d06bdbb04c5d920711
- name: zmk-nice-oled
  revision: ff9969d3fdd49cb9a3a8ee3934b96781f2265aee
```

This change was **committed and pushed** to the `eyelash_corne_touchpad` branch
of `from-urob-zmk-config` (commit `35172db`), so the prepare script reproduces
it automatically. With Zephyr back at 3.5, the correct interpreter is **Python
3.9** again — which is why the prepare default was kept at 3.9 (Problem 1).

#### Re-sync procedure used

Because `prepare_*` skips `west update` when `zmk/` already exists, after editing
the manifest the workspace was re-synced manually:

```bash
cd <workspace>
rm -rf .venv zmk/app/build
python3.9 -m venv .venv && source .venv/bin/activate
pip install west pyelftools
west update                       # pulls pinned zmk → Zephyr 3.5 + modules
pip install -r zephyr/scripts/requirements.txt
west zephyr-export
```

---

## Problem 4 — automation gotcha: `z: command not found` / `BASH_ENV`

### Symptom

While scripting the re-sync, a wrapper built with
`bash -c "$(declare -f fn); fn"` silently produced only:

```text
environment: line 4: z: command not found
```

…and none of the function body ran.

### Investigation / root cause

A `BASH_ENV`-referenced startup file invokes a `z` (zoxide/jump-style) helper
that isn't on `PATH` in the non-interactive shell. The stray failure plus
`set -e` interactions made the wrapped function appear to "do nothing."

### Solution

Run automation scripts hermetically — write a real script file and execute it
without inherited startup files:

```bash
setsid env -u BASH_ENV bash --noprofile --norc /tmp/resync.sh > /tmp/resync.log 2>&1 &
```

This is an *automation* footgun, not a defect in the build scripts, but it's
recorded here because it cost time and will recur in any unattended run on this
host.

---

## The complete fix, file by file

### `prepare_zmk_build_environment.sh`

- Added `prepare_eyelash_corne_touchpad()` (clones branch `eyelash_corne_touchpad`).
- Registered it in the `case "$device"` dispatch and the help/device list.
- Added `-y` / `--python` option + `python_bin` default.
- Reworked `check_python_venv` to resolve an interpreter (default `python3.9`,
  graceful fallback) and create the venv with it.

### `build_urob_zmk.sh`

- Added `-o` / `--output-name` (default `output_uf2`) so each variant's firmware
  gets its own output folder instead of clobbering `output_uf2/`.
- **Exported `ZEPHYR_BASE="$ZEPHYR_DIR"`** to pin Zephyr resolution (Problem 2).
- Threaded `output_name` through `compile_firmware`.

### `from-urob-zmk-config` (branch `eyelash_corne_touchpad`)

- Created the branch from `eyelash_corne`.
- Pinned `config/west.yml` projects to the known-good Zephyr-3.5 commit set
  (Problem 3). Committed (`35172db`) and pushed.

---

## Verification

A clean prepare + build on the pinned stack produced all four artifacts with no
failed boards:

```text
output_uf2_eyelash_corne_touchpad/
├── eyelash_corne_left_nice_epaper-zmk.uf2        657920 B
├── eyelash_corne_left_nice_epaper_new-zmk.uf2    674304 B
├── eyelash_corne_left_settings_reset-zmk.uf2     175104 B
└── eyelash_corne_right_nice_view_custom-zmk.uf2  585216 B
```

Cross-checked against the known-good `eyelash_corne` firmware — sizes match to
within ~512 bytes (UF2 block padding / build metadata), confirming an equivalent
build:

| Shield | Touchpad build | Known-good `eyelash_corne` |
| --- | --- | --- |
| `nice_epaper` | 657920 | 657408 |
| `nice_epaper_new` | 674304 | 673792 |
| `settings_reset` | 175104 | 174592 |
| `right nice_view_custom` | 585216 | 584704 |

Config-phase log confirmations:

```text
ZEPHYR_BASE: …/source_urob_zmk_eyelash_corne_touchpad/zephyr
-- Found Python3: …/.venv/bin/python3.9 (found suitable version "3.9.25", minimum required is "3.8")
zephyr_version: 350
```

---

## Known-good reference stack

| Component | Pin | Notes |
| --- | --- | --- |
| Zephyr | `v3.5.0+zmk-fixes` (`0fa4cc26`) | Selected via ZMK's `app/west.yml`. |
| ZMK | `6f85f48b…` (2025-04-04) | The manifest pin that anchors everything. |
| zmk-helpers | `8d7e7973…` | urob helpers. |
| zmk-tri-state | `ebbc1f0c…` | |
| mario-peripheral-animation | `1aa3950d…` | |
| zmk-nice-oled | `ff9969d3…` | branch `add_nice_epaper_new` at this commit. |
| Python | `python3.9` | 3.5 scripts break on 3.12 (`distutils` removed). |
| Zephyr SDK | `~/zephyr_sdk/` | `ZEPHYR_TOOLCHAIN_VARIANT=zephyr`. |

---

## Lessons & prevention

1. **Pin, don't float.** A keyboard config that imports ZMK at `revision: main`
   is a time bomb: the firmware source can be byte-identical yet stop building
   when upstream bumps Zephyr. Pin every manifest project to a commit for any
   branch you intend to rebuild later.
2. **Interpreter follows Zephyr.** Python ≥ 3.10 is *necessary but not
   sufficient* for Zephyr 4.x, and actively wrong for Zephyr 3.5. Keep the venv
   interpreter aligned with the pinned Zephyr (`--python`).
3. **Isolate Zephyr resolution.** On any machine with more than one west
   workspace, always set `ZEPHYR_BASE`; never trust the shared
   `~/.cmake/packages/Zephyr` registry to pick the right tree.
4. **Reproduce, then diff.** When a known-identical source fails, the difference
   is in the *dependencies*. Diffing the two workspaces' actual checked-out
   commits (Zephyr `VERSION`, `git rev-parse` per project) located the root
   cause faster than reading CMake traces.
5. **Re-prepare is not re-sync.** `prepare_*` intentionally skips `west update`
   once `zmk/` exists. After editing a manifest, run `west update` in the
   activated venv (or wipe the workspace) to actually pull the new pins.
6. **Run automation hermetically.** Use `env -u BASH_ENV bash --noprofile
   --norc <script>` for unattended steps on this host to avoid the `BASH_ENV`/`z`
   startup failure.
