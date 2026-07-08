# ZMK Eyelash Corne — Problems & Solutions

A detailed engineering log of the issues hit while adding and building the
`eyelash_corne_touchpad` variant with `prepare_zmk_build_environment.sh` and
`build_urob_zmk.sh`, including root-cause analysis and the exact fixes applied.

This log has **two phases**:

- **Part I — Build environment** (Problems 1–4): getting the pinned Zephyr-3.5
  stack to configure and compile at all (Python version, Zephyr resolution, the
  `Kconfig.defconfig` board-model break, and a `BASH_ENV` automation gotcha).
- **Part II — Touchpad integration** (Problems 5–8): wiring the Azoteq IQS5xx
  touchpad and its three custom gestures (pinch-zoom, three-finger swipe,
  auto-mouse layer) into that working stack. The integration recipe itself is
  [`eyelash_corne_touchpad_gestures_guide_good.md`](eyelash_corne_touchpad_gestures_guide_good.md).

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
- **Part II — Touchpad integration**
  - [Problem 5 — Touchpad driver silently disabled: `CONFIG_I2C` never enabled](#problem-5--touchpad-driver-silently-disabled-config_i2c-never-enabled)
  - [Problem 6 — Driver as an out-of-tree symlink breaks `zephyr_library_amend`](#problem-6--driver-as-an-out-of-tree-symlink-breaks-zephyr_library_amend)
  - [Problem 7 — Hand-editing `west.yml` dropped the `projects:` key](#problem-7--hand-editing-westyml-dropped-the-projects-key)
  - [Problem 8 — A display-less right half: removing the peripheral-OLED module](#problem-8--a-display-less-right-half-removing-the-peripheral-oled-module)
- **Part III — The OLED display & the shared I²C transport**
  - [Problem 9 — OLED image pixelized / garbled (wrong `nice_oled` module: an e-paper fork)](#problem-9--oled-image-pixelized--garbled-wrong-nice_oled-module-an-e-paper-fork)
  - [Problem 10 — OLED dark **and** touchpad dead: TWIM (EasyDMA) can't DMA from flash — use TWI](#problem-10--oled-dark-and-touchpad-dead-twim-easydma-cant-dma-from-flash--use-twi)
- **Part IV — The keyboard is the wrong board: matrix, keymap & polish**
  - [Problem 11 — No key registers: the board scans the wrong key matrix](#problem-11--no-key-registers-the-board-scans-the-wrong-key-matrix)
  - [Problem 12 — OLED blanks after ~30 s and doesn't come back](#problem-12--oled-blanks-after-30-s-and-doesnt-come-back)
  - [Problem 13 — Touchpad works but the right half floods `iqs5xx: Failed to read system info -5`](#problem-13--touchpad-works-but-the-right-half-floods-iqs5xx-failed-to-read-system-info--5)
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

# Part II — Touchpad integration (the `eyelash_corne_touchpad` gestures)

> **TL;DR (touchpad phase).** Wiring the Azoteq IQS5xx touchpad + three custom
> gestures into the working Zephyr-3.5 stack surfaced four more build-blocking
> issues: **(5)** the driver silently disabled because **`CONFIG_I2C` was never
> enabled** (the Corne display is SPI, so nothing pulls in I²C the way the rolio
> reference's I²C OLED does); **(6)** the driver consumed as a **symlink pointing
> outside the west workspace** broke `zephyr_library_amend`; **(7)** a hand-edit of
> `west.yml` **dropped the `projects:` key**; **(8)** removing the now-unused
> peripheral-OLED module meant building a **display-less right half** (a board
> entry with no shield), which the build-list parser couldn't express. Fixes:
> `CONFIG_I2C=y`; consume the driver as a real `west` checkout from the
> `techcaotri` fork; restore `projects:`; add a per-side `eyelash_corne_right.conf`
> and make `build.yaml`/`zmk_build.sh` shield-optional.

These are independent of Part I (the stack was already pinned and building); they
are about bringing up the touchpad and its gestures. The step-by-step integration
guide is [`eyelash_corne_touchpad_gestures_guide_good.md`](eyelash_corne_touchpad_gestures_guide_good.md).

---

## Problem 5 — Touchpad driver silently disabled: `CONFIG_I2C` never enabled

### Symptom

The **right** half (the only one carrying the touchpad node) failed to link:

```text
warning: INPUT_AZOTEQ_IQS5XX (defined at .../zmk-driver-azoteq-iqs5xx/drivers/input/Kconfig:1)
  was assigned the value 'y' but got the value 'n'.
...
ld.bfd: app/libapp.a(input_split.c.obj): .../src/pointing/input_split.c:77:
  undefined reference to `__device_dts_ord_34'
collect2: error: ld returned 1 exit status
```

The left half built fine; only the right (peripheral) — where the driver and the
`iqs5xx@74` node live — broke.

### Investigation

- `config/eyelash_corne.conf` set `CONFIG_INPUT_AZOTEQ_IQS5XX=y`, yet the build
  reported it "got the value 'n'." That phrasing means an **unmet Kconfig
  dependency** forced it back off.
- The driver's `drivers/input/Kconfig`:

  ```text
  menuconfig INPUT_AZOTEQ_IQS5XX
      depends on GPIO
      depends on I2C
      depends on INPUT
      depends on DT_HAS_AZOTEQ_IQS5XX_ENABLED
  ```

- Dumping the generated `.config` of the right build showed which dependency was
  missing:

  ```text
  CONFIG_GPIO=y
  CONFIG_INPUT=y
  CONFIG_DT_HAS_AZOTEQ_IQS5XX_ENABLED=1     # node present + binding matched
  # CONFIG_I2C is absent                     # <-- the unmet dependency
  ```

- The `__device_dts_ord_34` link error was a **downstream symptom**: with the
  driver excluded, the `tps43` (`iqs5xx@74`) device object is never instantiated,
  so the `zmk,input-split` forwarder that references `device = <&tps43>` has a
  dangling `DEVICE_DT_GET` → an undefined device ordinal at link time.

### Root cause

`CONFIG_I2C` is **not** auto-enabled merely by adding an `&i2c1`/TWIM node to the
overlay on this stack. In the **rolio reference** (a Sofle) the touchpad shares
the **OLED's I²C bus**, and the Sofle shield's `Kconfig.defconfig` does
`config I2C / default y / if ZMK_DISPLAY` — so I²C arrives *through the display*.
On the **eyelash_corne the display is SPI** (OLED/e-paper on `spi0`, RGB on
`spi3`), so nothing pulls in the I²C subsystem, and the driver's `depends on I2C`
quietly drops `CONFIG_INPUT_AZOTEQ_IQS5XX` to `n`.

### Solution

Enable I²C explicitly in the shared conf (`config/eyelash_corne.conf`):

```ini
# CONFIG_I2C must be set explicitly: the eyelash_corne display is SPI, so unlike
# the rolio reference (OLED on I2C) nothing else pulls in the I2C subsystem.
CONFIG_I2C=y
CONFIG_INPUT=y
CONFIG_INPUT_AZOTEQ_IQS5XX=y
CONFIG_ZMK_POINTING=y
```

It is harmless on the left half (no I²C node there, so the bus driver
instantiates nothing). With `CONFIG_I2C=y` the dependency chain is satisfied, the
driver compiles, the `tps43` device exists, and `input_split` links.

> **Diagnostic worth keeping:** an `undefined reference to __device_dts_ord_NN`
> coming from `input_split.c` almost always means *the referenced input device's
> driver didn't compile* — check that the driver's Kconfig dependencies are all
> met, **before** suspecting the split wiring.

---

## Problem 6 — Driver as an out-of-tree symlink breaks `zephyr_library_amend`

### Symptom

A first attempt linked the driver into the workspace via a **symlink** to an
editable copy *outside* the west workspace (so it could be edited without
pushing). CMake configure then failed:

```text
CMake Error at .../zephyr/cmake/modules/extensions.cmake:481 (target_sources):
  Cannot specify sources for target
  "..__..__zmk-driver-azoteq-iqs5xx__drivers__input" which is not built by this project.
Call Stack:
  ... zephyr_library_sources
  .../zmk-driver-azoteq-iqs5xx/drivers/input/CMakeLists.txt:3 (zephyr_library_sources_ifdef)
```

### Investigation

- The driver's `drivers/input/CMakeLists.txt` uses the standard ZMK external-input
  pattern — `zephyr_library_amend()` then `zephyr_library_sources_ifdef(...)`.
  `zephyr_library_amend()` **re-opens** the library Zephyr created for the module
  during module processing; it does not create one.
- The offending library name — `..__..__zmk-driver-azoteq-iqs5xx__drivers__input`
  — encodes a path with **two `../` segments**, i.e. CMake resolved the module to a
  location *above* the workspace. The symlink at `<workspace>/zmk-driver-…` pointed
  to `<workspace>/../zmk-driver-…`; CMake follows the symlink to its real
  (out-of-tree) path, and the per-module library that module processing set up no
  longer matches the name `zephyr_library_amend()` computes → "not built by this
  project."
- Every other module (zmk-helpers, zmk-nice-oled, …) is a **real directory at the
  workspace root** and builds fine — confirming the symlink-to-outside-the-tree
  was the trigger. Replacing the symlink with a plain `cp -r` of the same files
  made the right half build and link cleanly.

### Root cause

`zephyr_library_amend()` relies on the module being a normal in-tree Zephyr module
whose library context is established by `west`/module processing. A symlink whose
real target is outside the workspace breaks the 1:1 mapping between the module's
manifest path and its CMake library target.

### Solution

Stop symlinking. Consume the driver the way every other module is consumed — a
**real `west`-managed checkout inside the workspace**:

1. Push the edited driver to a fork (`techcaotri/zmk-driver-azoteq-iqs5xx`, branch
   `feature/zoom-and-swipe`; this is Part B of the gestures guide anyway).
2. Point `config/west.yml`'s driver project at that fork
   (`remote: techcaotri`, `revision: feature/zoom-and-swipe`).
3. Let `west update zmk-driver-azoteq-iqs5xx` check it out at
   `<workspace>/zmk-driver-azoteq-iqs5xx` (a real directory, clean path).

The interim `link_local_iqs5xx_driver()` helper in
`prepare_zmk_build_environment.sh` was removed; `prepare_*` now simply `west
update`s the module (including `west update zmk-driver-azoteq-iqs5xx` when the
workspace already exists).

> **Why the symlink was tempting:** to iterate on driver C source locally without
> a push round-trip. It works for *vendored* modules but not for ones consumed
> through `zephyr_library_amend()`. The fork + `west update` flow is correct and is
> what the gestures guide prescribes.

---

## Problem 7 — Hand-editing `west.yml` dropped the `projects:` key

### Symptom

```text
$ west manifest --path
FATAL ERROR: can't run west manifest; it requires the manifest, which was not available.
```

`west list` returned nothing; the whole workspace looked broken.

### Investigation / root cause

A targeted edit that inserted the Azoteq remote accidentally **removed the
`projects:` mapping key** that separates the `remotes:` block from the project
list. With no `projects:` key, every project entry parsed as a continuation of
`remotes:`, so west saw a manifest with **zero projects** → "manifest not
available."

### Solution

Restore the single `projects:` line. Trivial, but the lesson is to **validate the
manifest after any hand-edit** rather than eyeballing it:

```bash
west manifest --validate    # parse + resolve imports; non-zero exit on error
west list                   # should show zmk (+ Zephyr via import) and every module
```

> `west.yml` is whitespace- and key-structure-sensitive. `west manifest
> --validate` catches a dropped key, a mis-indented project, or a bad `import`
> instantly; "it looks right" does not.

---

## Problem 8 — A display-less right half: removing the peripheral-OLED module

### Context

The touchpad physically replaced the **right-half OLED**, so
`mario-peripheral-animation` — whose only role here was to provide the
`nice_view_custom` peripheral-display shield — became dead weight and was removed
from `config/west.yml` (along with the now-unused `gpeye` and `aym1607` remotes).
Removing it has two consequences, each needing its own fix.

### 8a — The right half must build with the display **off**

`nice_view_custom` provided the right half's `zephyr,display` device. Dropping it
while `CONFIG_ZMK_DISPLAY=y` (set in the shared `eyelash_corne.conf`, which the
**left** half still needs for its e-paper) would fail to build (display enabled,
no display device).

**Solution — a per-side override.** ZMK loads a board-name conf in *addition* to
the shared one, so a new **`config/eyelash_corne_right.conf`** turns the display
off for the right half only:

```ini
CONFIG_ZMK_DISPLAY=n
CONFIG_ZMK_DISPLAY_STATUS_SCREEN_CUSTOM=n
```

Confirmed from the generated `.config` (no `CONFIG_ZMK_DISPLAY=y` on the right)
and from the firmware size dropping ~597 KB → ~378 KB, while the left half keeps
its screen. `CONFIG_INPUT_AZOTEQ_IQS5XX=y`/`CONFIG_I2C=y` remain set on the right.

### 8b — A `build.yaml` entry with **no shield** broke the build-list parser

`from-urob-zmk-config/scripts/zmk_build.sh` built its board and shield lists with
two **independent** greps, then paired them by index:

```bash
BOARDS="$(grep '... board:'  build.yaml | sed ...)"   # 4 lines
SHIELDS="$(grep '... shield:' build.yaml | sed ...)"  # only 3 lines once the right loses its shield
```

Make the right entry shield-less and the arrays misalign (the right board would
pair with `settings_reset`, the last board with nothing). Plain word-splitting
also **drops empty elements**, so an "empty shield" line wouldn't rescue it.

**Solution — parse pairs, preserve blanks, pass the shield as an array:**

```bash
# Emit exactly one shield per board entry (empty for a display-less board).
SHIELDS="$(awk '
  /^[[:space:]]*-[[:space:]]*board:/ { if (seen) print sh; sh=""; seen=1; next }
  /^[[:space:]]*shield:/ { s=$0; sub(/^[^:]*:[[:space:]]*/,"",s); sh=s }
  END { if (seen) print sh }
' build.yaml)"

mapfile -t BOARDS  <<< "$BOARDS"     # mapfile keeps empty lines (word-splitting drops them)
mapfile -t SHIELDS <<< "$SHIELDS"

# compile_board(): an empty shield contributes no -DSHIELD argument.
if [[ -n $2 ]]; then SHIELD_OPTS=("-DSHIELD=$2"); else SHIELD_OPTS=(); fi
west build ... -- ... "${SHIELD_OPTS[@]}" ...
```

These changes live on the `eyelash_corne_touchpad` branch of
`from-urob-zmk-config`, so they cannot affect the other variants (each variant is
a separate branch). A shield-less board's firmware is suffixed `nodisplay`, e.g.
`eyelash_corne_right_nodisplay-zmk.uf2`.

---

# Part III — The OLED display & the shared I²C transport

Parts I–II got the firmware building and the touchpad driver compiled. The next two
problems only surfaced when the firmware was **flashed on real hardware** and
compared, symptom-by-symptom, against the working `zmk-config-rolio` reference —
which is the *same keyboard* (42-key Corne + TPS65 touchpad + 128×32 SSD1306 OLED).
The hardware later turned out to carry a **128×32 SSD1306 OLED on the left** (not the
e-paper the config was first written against), so the display path was reworked to
match rolio: OLED on I²C0 `@0x3c`, driven by the upstream `nice_oled` widgets.

## Problem 9 — OLED image pixelized / garbled (wrong `nice_oled` module: an e-paper fork)

### Symptom

The left 128×32 SSD1306 OLED lit up but rendered a **pixelized / garbled / doubled**
image instead of the clean status screen.

### Investigation

- The resolved panel node (`ssd1306@3c`: `width 128`, `height 32`,
  `multiplex-ratio 0x1f`, `com-sequential`, `segment-remap`, `com-invdir`,
  `inversion-on`, `prechargep 0x22`) was **byte-identical** to rolio's.
- The LVGL config was already 1-bit (`LV_COLOR_DEPTH_1`, `LV_Z_BITS_PER_PIXEL=1`,
  `LV_Z_VDB_SIZE=64`) — identical to rolio. So colour depth was not it.
- The one divergence was the **`zmk-nice-oled` module revision**. The eyelash pinned
  `techcaotri/zmk-nice-oled@ff9969d`; its commit history (*"…for 'nice_epaper'
  config"*, *"add 'nice_epaper_new'"*) shows it was tuned for an **e-paper** panel —
  different fonts, assets and layout than the OLED. rolio pins upstream
  `mctechnology17/zmk-nice-oled@main`.

### Root cause

The e-paper-tuned rendering module drew for a different panel geometry/asset set →
garbage on the SSD1306.

### Solution

Follow rolio: repoint `config/west.yml` to `mctechnology17/zmk-nice-oled@main` (add
the `mctechnology17` remote) and `west update zmk-nice-oled`. The module tree is then
**byte-identical** to rolio's (`46f824a`). Also drop the conf's `*_LUNA` widget
overrides and use the module's **default** widgets like rolio (WPM + bongo-cat,
status, layer, fixed modifier indicators, HID indicators):

```ini
# config/eyelash_corne.conf — was: CONFIG_NICE_OLED_WIDGET_WPM_LUNA=y (+ *_LUNA)
CONFIG_ZMK_DISPLAY_STATUS_SCREEN_CUSTOM=y
CONFIG_ZMK_DISPLAY_WORK_QUEUE_DEDICATED=y
# (no *_WIDGET_* overrides → module defaults, exactly as rolio)
```

The `*_LUNA` overrides had a second cost: on the upstream module they force-compile
`luna.c` alongside the default `bongo_cat.c`, which define the same globals
(`current_anim_state`, `idle/slow/mid/fast_imgs`) with no `extern` → a **`multiple
definition`** link error. Using rolio's defaults resolves both.

## Problem 10 — OLED dark **and** touchpad dead: TWIM (EasyDMA) can't DMA from flash — use TWI

### Symptom

After Problem 9's module fix the OLED went **fully dark** (no pixels), and the
**touchpad did not work at all** — yet the *same hardware* runs rolio's firmware
(both `master` and `tps65-oled`) with a working OLED **and** touchpad.

### Investigation

- Both devices sit on `i2c0` — OLED `@0x3c` (left), touchpad `@0x74` (right). "Both
  broken on the eyelash firmware, both fine on rolio, same physical keyboard" points
  at the **shared I²C bus**, not at either device's node or driver.
- Diffing the *resolved* devicetree `i2c@40003000` node between the eyelash and rolio
  builds surfaced the only hardware difference left:

  | | eyelash (broken) | rolio (works) |
  | --- | --- | --- |
  | `compatible` | `nordic,nrf-twim` | `nordic,nrf-twi` |
  | `clock-frequency` | `400000` (right half) | `100000` |

  The eyelash's `eyelash_corne_{left,right}.dts` explicitly set
  `compatible = "nordic,nrf-twim"`; rolio's `&pro_micro_i2c` keeps the board default
  `nordic,nrf-twi`.

### Root cause

On the nRF52840, **TWIM** is the EasyDMA I²C master. EasyDMA transfers must source
their bytes from **RAM** — it **cannot read from flash / RODATA**. Both the Zephyr
`ssd1306` panel driver and the Azoteq `iqs5xx` driver issue their init/command
sequences from **`const` (flash-resident)** byte arrays. On TWIM those writes fail
(EasyDMA can't fetch the source bytes), so the OLED never initialises and the touchpad
never comes up — **silently**, with no build error. The legacy **TWI** driver clocks
bytes out one at a time from *any* memory, so it works. rolio uses TWI — which is
exactly why the two peripherals only worked under rolio's firmware.

### Solution

Match rolio exactly: force the legacy TWI on **both** halves (`i2c0` is the same
peripheral instance on each), and drop the right half's 400 kHz override back to
rolio's 100 kHz:

```dts
&i2c0 {
    compatible = "nordic,nrf-twi";     /* NOT nordic,nrf-twim (EasyDMA) */
    status = "okay";
    pinctrl-0 = <&i2c0_default>;       /* NRF_PSEL(TWIM_SDA/SCL, 0, 17/20) — */
    pinctrl-1 = <&i2c0_sleep>;         /* the TWIM_* PSEL macros are correct for TWI too */
    clock-frequency = <100000>;        /* right half only; was 400000 */
    /* … ssd1306@3c (left) / iqs5xx@74 (right) … */
};
```

Verified: both halves' **resolved** devicetree now shows `compatible = "nordic,nrf-twi"`
@ `0x186a0` (100 kHz), identical to rolio's known-good build. The fix firmware was
rebuilt with the `zmk-usb-logging` snippet (`-l`) so the SSD1306 / IQS5xx init can be
watched on the USB-CDC console for on-hardware confirmation.

> **Why static config-diffing missed it.** The `nice_oled` module, the display
> Kconfig, the LVGL settings and the panel node were *all* byte-identical to rolio.
> The only divergence was the I²C **binding** — a board-transport detail that does not
> change the framebuffer *contents*, only whether the bytes ever reach the panel. The
> tell for a transport (bus-driver) bug rather than a device/config one: **two
> independent peripherals both dead on one firmware and both alive on another, on the
> same hardware.** When that happens, diff the *resolved* devicetree of the shared bus.

---

# Part IV — The keyboard is the wrong board: matrix, keymap & polish

With the OLED and touchpad alive (Parts I–III), the halves paired and the touchpad
moved the cursor — but **no key ever typed**. Root cause: the firmware was built for
the wrong *board*. `eyelash_corne` (from `a741725193/zmk-new_corne`) is a **5×7** matrix
with encoder + joystick keys; this hardware is a **plain 42-key Corne wired exactly like
`zmk-config-rolio`** (`nice_nano_v2` + `sofle`). So the kscan scanned GPIOs the switches
aren't connected to.

## Problem 11 — No key registers: the board scans the wrong key matrix

### Symptom

Keys, OLED and BLE all "work" (OLED lit, connects to the host), but pressing any key —
on either half, even over USB — types nothing. A boot log also showed
`<err> zmk: Too many combos for key position 24`.

### Investigation

- USB-CDC debug logging (`CONFIG_ZMK_LOG_LEVEL_DBG=y` + `-l`) on the central: pressing
  keys produced **no** `kscan_matrix_read` / position events at all. The matrix isn't
  detecting presses → it's scanning the wrong pins.
- The resolved kscan (`kscan_matrix_init_*_inst: Configured pin …`) confirmed the
  `eyelash_corne` board drives **5 rows × 7 cols** on P0.19/8/12/11,P1.9 × P0.3/28/30/…
- rolio's `sofle` (which runs on this exact hardware) uses **4 rows × 6 cols** on
  entirely different pins (`&pro_micro` → P0.02/P1.15/P1.13/P1.11 × P0.29/P1.04/P0.11/
  P1.00/P0.24/P0.22). The user has **no encoder/joystick** → it's a plain Corne.

### Root cause

The `eyelash_corne` board definition (kscan, transform, physical-layout) does not match
the hardware. The user's board is a `nice_nano_v2`-wired Corne; only the I²C peripherals
(OLED/touchpad) happened to share pins, which is why *they* worked while the key matrix
did not.

### Solution — make the board = rolio's `sofle`, and the keymap 42-key

Board (`boards/arm/eyelash_corne/…`), translating rolio's `&pro_micro` pins to raw nRF
(this board has no `pro_micro` nexus):

```dts
/* eyelash_corne.dtsi */
&kscan0 {                            /* rows only; cols are per-half */
    row-gpios = <&gpio0 2 …>, <&gpio1 15 …>, <&gpio1 13 …>, <&gpio1 11 …>;  /* 4 rows */
};
default_transform: keymap_transform_0 { columns = <12>; rows = <4>;  map = < …42 RC()… >; };
/* eyelash_corne_left.dts / _right.dts: same 6 col-gpios on both halves */
&kscan0 { col-gpios = <&gpio0 29 …>,<&gpio1 4 …>,<&gpio0 11 …>,<&gpio1 0 …>,<&gpio0 24 …>,<&gpio0 22 …>; };
/* RIGHT half only — shift its columns into transform cols 6..11 (like sofle_right.overlay) */
&default_transform { col-offset = <6>; };
```

Keymap: the urob keymap is parameterized by `X_*` "extra key" macros (see the
`eyelash_corne_dongle` config's `extra_keys.h` — the base layout is 34 keys, extras are
*added*). For a plain 42-key Corne, **empty the joystick middle-column macros**
(`X_MT/X_MM/X_MB` + `_M`/`_A` variants) so every alpha row is 12 keys, keep the outer
columns (`X_LT`…) and the middle thumb (`X_MH` = SPACE/RET, the 3rd thumb). Renumber
`key-labels/eyelash_corne_42.h` to a contiguous **0..41** (drop `JT0/JM/EB0/JB0`) so
combos track it, and delete the encoder `&inc_dec_kp` sensor line. Result: exactly 42
bindings/layer, matching the 42-position transform (the "Too many combos" error also
disappears because positions renumber correctly). Verified on hardware: both halves type.

## Problem 12 — OLED blanks after ~30 s and doesn't come back

### Symptom

The OLED lights at boot but goes dark after a short idle and only returns on reset.

### Root cause

The shared conf inherited `CONFIG_ZMK_DISPLAY_BLANK_ON_IDLE=y` with a 30 s
`CONFIG_ZMK_IDLE_TIMEOUT`, so the panel blanks on idle. rolio keeps its display on.

### Solution

Match rolio in `config/eyelash_corne.conf`:

```ini
CONFIG_ZMK_DISPLAY_BLANK_ON_IDLE=n
CONFIG_ZMK_IDLE_TIMEOUT=600000     # 10 min, as rolio's sofle_left.conf
```

## Problem 13 — Touchpad works but the right half floods `iqs5xx: Failed to read system info -5`

### Symptom

The touchpad functions (move, scroll, two-finger right-click, drag) but the right-half
USB-CDC log is flooded, hundreds/sec, with:

```text
<err> i2c_nrfx_twi: Error 0x0BAE0001 occurred for message 0
<err> iqs5xx: Failed to read system info 0: -5      (-EIO / I²C NACK)
```

### Investigation / root cause

The IQS5xx initialises (`IQS5xx trackpad initialized`) and enough reads succeed to drive
the cursor, but many reads NACK. The flood is **massively amplified by the debug setup**:
the peripheral was on **USB streaming DBG logs**, and *every* I²C failure emits a log line
over USB-CDC, which saturates the CPU — and the legacy **`nordic,nrf-twi`** driver is
**blocking and timing-sensitive**, so the logging starves its transactions and they NACK,
producing more error logs. rolio (no logging) shows no such flood. (The concurrent
`<wrn> bt_gatt: Link is not encrypted` / `send_position_state_callback: Error notifying
-128` lines are transient split-pairing warnings before encryption completes — harmless.)

### Solution

Remove the debug logging for the production firmware: delete `CONFIG_ZMK_LOG_LEVEL_DBG=y`
and build **without** `-l` (no `zmk-usb-logging` snippet). With no USB-CDC log flood the
CPU no longer starves the TWI driver, and in normal (battery, no-USB) use the touchpad
runs cleanly — confirmed on hardware.

> **If the NACKs ever persist in production** (e.g. battery drains fast / the pad lags),
> the real fix is driver-side: gate the IQS5xx reads on the **RDY** pin so the host only
> reads inside the chip's data-ready window (the Azoteq part NACKs reads issued outside
> it), or add I²C bus-recovery. That is a change to the `zmk-driver-azoteq-iqs5xx` fork.

## Problem 14 — OLED dies after a long idle and only a settings-reset revives it

### Symptom

Different from Problem 12 (which was a 30 s idle *blank*). Here the OLED stays on through
normal use and idle, but after a **long** wait (~1 h in the original config) it goes dark
and **will not come back** on keypress, on wake, or on re-flashing the firmware — the
*only* thing that revives it is flashing `settings_reset` and then the OLED firmware.

### Investigation

The "needs a settings-reset" part is the tell: something **persisted in flash** is holding
the display off across a reboot (a plain re-flash boots the same way and doesn't fix it;
only clearing saved settings does). A fast-repro debug build (`CONFIG_ZMK_IDLE_SLEEP_TIMEOUT`
= 30 s, USB logging, plus temporary instrumentation in `activity.c`/`ext_power_generic.c`
to log ext-power state and to deep-sleep even on USB) showed the OLED **recovering** every
sleep/wake — because 30 s is far below the 10 min idle timeout. That mismatch localized the
trigger to the **idle** path, not deep sleep itself.

### Root cause

The OLED shares the **EXT_POWER** rail (nice_nano_v2 switched VCC, P0.13) with the WS2812
underglow. The config enabled RGB underglow (`CONFIG_ZMK_RGB_UNDERGLOW=y`,
`CONFIG_ZMK_RGB_UNDERGLOW_AUTO_OFF_IDLE=y`) **for LEDs this hardware does not have**, and
`CONFIG_ZMK_RGB_UNDERGLOW_EXT_POWER` defaults `y`. So:

1. At the 10-min idle mark, RGB auto-off runs → `zmk_rgb_underglow_off()` → `ext_power_disable()`
   (`app/src/rgb_underglow.c`), which sets status=0 **and schedules a settings save**.
2. The board keeps sitting idle, so the 60 s `CONFIG_ZMK_SETTINGS_SAVE_DEBOUNCE` elapses and
   `ext_power/state=0` is **written to flash**.
3. At the deep-sleep timeout the SoC powers off; the keypress wake **resets** the board.
4. On boot, ext-power inits ON, then settings load, `ext_power_settings_set_status()` reads
   the persisted `0` and **re-disables the rail** → OLED (on that rail) stays dark.
5. `settings_reset` erases the saved `0`, so ext-power defaults back ON — which is why only
   that revived it.

(Deep sleep's own suspend also calls `ext_power_disable`, but `sys_poweroff()` fires before
the 60 s debounce, so that path never persists — confirmed: the wake log always showed
`status=1`. The idle path is the only one that stays alive long enough to save.)

### Solution

Match zmk-config-rolio (which enables **no** underglow, and never had this) and the actual
hardware (no underglow/backlight LEDs) — disable both in `config/eyelash_corne.conf`:

```ini
# RGB underglow OFF: no LEDs here, and its EXT_POWER coupling bricked the OLED (above).
# CONFIG_WS2812_STRIP=y
# CONFIG_ZMK_RGB_UNDERGLOW=y
# CONFIG_ZMK_RGB_UNDERGLOW_AUTO_OFF_IDLE=y  (etc.)
# CONFIG_ZMK_BACKLIGHT=y                    (no coupling, but LED-less + not in rolio)
```

With underglow gone nothing disables EXT_POWER while the board is awake, so the OLED rail
stays powered through idle; deep sleep still powers everything off and the wake-reset brings
it back with `status=1`. Confirmed on hardware: the OLED returns after every sleep/wake cycle.

> Note the general trap: **any** feature that calls `ext_power_disable()` (RGB underglow's
> `*_EXT_POWER`/`*_AUTO_OFF_IDLE`) will, on a board where the OLED shares that rail, persist
> the rail OFF and brick the display until a settings-reset. Only enable EXT_POWER-coupled
> peripherals that physically exist.

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

### Touchpad integration (Part II)

- **`config/eyelash_corne.conf`** — `CONFIG_I2C=y` (Problem 5), plus
  `CONFIG_INPUT`, `CONFIG_INPUT_AZOTEQ_IQS5XX`, `CONFIG_ZMK_POINTING`.
- **`config/eyelash_corne_right.conf`** (new) — `CONFIG_ZMK_DISPLAY=n` so the
  right half builds display-less (Problem 8a).
- **`config/west.yml`** — driver project pointed at the `techcaotri` fork
  (`feature/zoom-and-swipe`, Problem 6); `mario-peripheral-animation` plus the
  `gpeye`/`aym1607` remotes removed (Problem 8); the dropped `projects:` key
  restored (Problem 7).
- **`build.yaml`** — the `eyelash_corne_right` entry is now shield-less
  (Problem 8a).
- **`scripts/zmk_build.sh`** — board/shield list parsed as pairs with `mapfile`,
  and the shield passed as a bash array so a shield-less board builds (Problem 8b).
- **`boards/arm/eyelash_corne/*.dts*`** and **`config/base.keymap`** + the forked
  driver — the touchpad bring-up and the three gestures themselves (see the
  gestures guide).

### `prepare_zmk_build_environment.sh` (Part II)

- Removed the interim `link_local_iqs5xx_driver` symlink helper; the driver is now
  pulled as a normal `west` module from the fork (Problem 6).

---

## Verification

A clean prepare + build on the pinned stack produced all four artifacts with no
failed boards:

```text
output_uf2_eyelash_corne_touchpad/
|-- eyelash_corne_left_nice_epaper-zmk.uf2        657920 B
|-- eyelash_corne_left_nice_epaper_new-zmk.uf2    674304 B
|-- eyelash_corne_left_settings_reset-zmk.uf2     175104 B
`-- eyelash_corne_right_nice_view_custom-zmk.uf2  585216 B
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
7. **A devicetree node does not enable its bus.** Adding an `&i2c1` node does not
   set `CONFIG_I2C` unless something `select`s or `default y`s it. When a driver
   `depends on` a subsystem, enable that subsystem explicitly in `*.conf` — and
   read the "assigned 'y' but got 'n'" Kconfig warning as "an unmet dependency."
8. **Consume modules through `west`, not symlinks.** ZMK input drivers add their
   sources via `zephyr_library_amend()`, which needs a real in-tree module path.
   Push to a fork and `west update`; a symlink to an out-of-tree copy breaks the
   module's CMake library ("not built by this project").
9. **Validate `west.yml` after editing.** `west manifest --validate` followed by
   `west list` catches a dropped `projects:` key, a mis-indented project, or a bad
   import in seconds — far faster than a confusing "manifest not available."
10. **A per-board `.conf` overrides the shared one.** The build loads a
   board-specific `eyelash_corne_right.conf` in *addition* to the shared
   `eyelash_corne.conf` (later wins), which is how the right half can drop the
   display while the left keeps it.
11. **Mirror the reference's module pins; don't fork blindly.** When a repo is
   "the same keyboard" (here `zmk-config-rolio`), pin shared display/widget modules
   to the *same* source it uses. A `zmk-nice-oled` fork tuned for an e-paper panel
   rendered garbage on the SSD1306 OLED; switching to rolio's
   `mctechnology17/zmk-nice-oled@main` (and its default widgets) fixed it (Problem 9).
12. **Two peripherals dead on one firmware, alive on another → suspect the shared
   bus, and diff the *resolved* devicetree.** The eyelash forced
   `nordic,nrf-twim` (EasyDMA, RAM-only source) on `i2c0`; rolio used
   `nordic,nrf-twi`. TWIM cannot transmit the SSD1306 / IQS5xx drivers' `const`
   (flash) command buffers, so the OLED **and** the touchpad silently failed —
   while the same hardware worked under rolio. Static config/DT-node diffing missed
   it because only the bus *binding* differed; the resolved `i2c@40003000` node
   showed it at once (Problem 10).
13. **Peripherals working ≠ right board.** The OLED and touchpad came up because
   they sit on standard I²C pins, which masked that the whole *board* was wrong for
   this hardware — the **key matrix** scanned pins the switches aren't wired to. When
   keys are totally dead, log the kscan (`kscan_matrix_read` / `Configured pin …`)
   and compare the *resolved* rows/cols to a known-good config (rolio's `sofle`);
   match the hardware, don't assume the board name (Problem 11).
14. **Debug logging can *manufacture* errors.** Heavy `CONFIG_ZMK_LOG_LEVEL_DBG`
   over USB-CDC floods the CPU; a *blocking* driver (legacy `nordic,nrf-twi`) then
   starves and its transactions NACK — so the logs report I²C errors the production
   firmware doesn't have. Confirm a suspicious flood is real by testing without
   logging before "fixing" it (Problem 13).
