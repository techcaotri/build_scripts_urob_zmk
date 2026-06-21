# build_scripts_urob_zmk

Helper scripts that **set up** and **compile** [urob](https://github.com/urob)-style
[ZMK](https://zmk.dev) firmware for several split keyboards from a single,
reproducible workflow.

The scripts wrap the usual ZMK / [west](https://docs.zephyrproject.org/latest/develop/west/index.html)
ceremony (clone the right config branch, create an isolated Python virtual
environment, `west init` / `west update`, export the Zephyr CMake package, then
build every board/shield listed in `build.yaml`) so that going from a clean
machine to a folder full of `.uf2` files is two commands.

All keyboard-specific configuration lives in the companion repository
[`git@github.com:techcaotri/from-urob-zmk-config.git`](https://github.com/techcaotri/from-urob-zmk-config),
which has **one branch per keyboard variant**. These scripts pick the correct
branch for the device you ask for.

---

## Table of contents

- [Repository layout](#repository-layout)
- [Supported devices](#supported-devices)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [`prepare_zmk_build_environment.sh`](#prepare_zmk_build_environmentsh)
- [`build_urob_zmk.sh`](#build_urob_zmksh)
- [How a prepared workspace is structured](#how-a-prepared-workspace-is-structured)
- [Output firmware](#output-firmware)
- [Worked example: the `eyelash_corne_touchpad` variant](#worked-example-the-eyelash_corne_touchpad-variant)
- [Versioning &amp; reproducibility (important)](#versioning--reproducibility-important)
- [Troubleshooting](#troubleshooting)

---

## Repository layout

| Path | Purpose |
| --- | --- |
| `prepare_zmk_build_environment.sh` | One-time setup per variant: clone config, create `.venv`, `west init`/`update`, install requirements. |
| `build_urob_zmk.sh` | Compile firmware for an already-prepared workspace and collect the `.uf2`/`.bin` files. |
| `docs/ZMK_Corne_Problems_And_Solutions.md` | Deep dive: root-cause analysis of the build issues (Python/Zephyr versions, CMake Zephyr resolution, manifest pinning) and their fixes. |
| `output_uf2/` | Default output directory for compiled firmware. |
| `output_uf2_<name>/` | Per-variant output directory when `build_urob_zmk.sh -o <name>` is used. |
| `firmware_nice_epaper/`, `*.7z`, `*.log`, `*.tar.gz` | Archived firmware / build logs (not produced by the scripts directly). |
| `LICENSE` | License. |

> The actual board definitions, keymaps, `build.yaml` and the lower-level
> `scripts/zmk_build.sh` all live in `from-urob-zmk-config` (cloned into the
> workspace you choose with `-p`), **not** in this folder.

---

## Supported devices

`prepare_zmk_build_environment.sh -d <device>` understands the following values.
Each maps to a branch of `from-urob-zmk-config`:

| `-d` device | `from-urob-zmk-config` branch | Keyboard |
| --- | --- | --- |
| `adv360-pro` | `tripham_adv360_pro` | Kinesis Advantage360 Pro |
| `sofle_v2` | `tripham_sofle` | Sofle v2 (bluemicro840) |
| `sofle_nicenano_v2` | `tripham_choc_nicenanov2_sofle` | Sofle nice!nano v2 choc |
| `corne_nicenano_v2_choc` | `tripham_corne_choc` | Corne nice!nano v2 choc |
| `eyelash_corne` | `eyelash_corne` | Eyelash Corne (nice!nano) |
| `eyelash_corne_touchpad` | `eyelash_corne_touchpad` | Eyelash Corne **with touchpad** |
| `eyelash_corne_dongle` | `eyelash_corne_dongle` | Eyelash Corne with a dongle receiver |

The Sofle/Corne preparers additionally symlink a `keypos_*.h` helper into the
config's `zmk-nodefree-config` tree; the Advantage360 and eyelash variants don't
need it.

---

## Prerequisites

- **Linux** with `bash`, `git`, and an SSH key authorized for the
  `techcaotri/from-urob-zmk-config` repository (the scripts clone over SSH).
- **Python** — `python3.9` is the default interpreter for the venv (see the
  `--python` flag and the [reproducibility note](#versioning--reproducibility-important)).
  Newer Zephyr (4.x) requires Python ≥ 3.10; pass `--python python3.12` for those.
- **Zephyr SDK** installed under `~/zephyr_sdk/`. `build_urob_zmk.sh` exports:
  - `ZEPHYR_TOOLCHAIN_VARIANT=zephyr`
  - `ZEPHYR_SDK_INSTALL_DIR=~/zephyr_sdk/`
- Standard build tooling on `PATH`: `cmake`, `ninja`, `dtc`, and the usual C
  build dependencies that ZMK/Zephyr expect for a local (non-Docker) build.

`west` itself does **not** need to be pre-installed — `prepare_*` installs it
into the per-workspace `.venv`.

---

## Quick start

```bash
# 1) Prepare an isolated workspace for a variant (clones, venv, west update).
./prepare_zmk_build_environment.sh \
    -d eyelash_corne_touchpad \
    -p /path/to/Eyelash-Corne-Touchpad/source_urob_zmk_eyelash_corne_touchpad

# 2) Build it. Firmware lands in ./output_uf2_eyelash_corne_touchpad/
./build_urob_zmk.sh \
    -p /path/to/Eyelash-Corne-Touchpad/source_urob_zmk_eyelash_corne_touchpad \
    -o output_uf2_eyelash_corne_touchpad
```

The `-p` path is the **single source of truth** shared by both scripts: prepare
writes the workspace there, and build reads it back from the same location.

---

## `prepare_zmk_build_environment.sh`

Sets up a self-contained build workspace for one keyboard variant. Safe to
re-run: every step is guarded (`if [ ! -d ... ]`), so it skips work that is
already done.

### Usage

```text
prepare_zmk_build_environment.sh [-h] [-d DEVICE] [-p PATH] [-y PYTHON] [-v]
```

### Options

| Option | Argument | Description |
| --- | --- | --- |
| `-h`, `--help` | — | Show help and exit. |
| `-d`, `--device` | `DEVICE` | Variant to prepare (see [Supported devices](#supported-devices)). **Required.** |
| `-p`, `--path` | `PATH` | Directory to create/use as the build workspace. Created if missing. **Required.** |
| `-y`, `--python` | `PYTHON` | Python interpreter used to create `.venv` (e.g. `python3.12`). Defaults to the first of `python3.9 → python3.10 → python3.11 → python3.12 → python3` found. |
| `-v`, `--version` | — | Print script version and exit. |

### What it does (in order)

1. `cd` into `-p PATH` (created with `mkdir -p`).
2. **`check_python_venv`** — reuse an existing `.venv` if present; otherwise
   create one with the resolved interpreter and activate it.
3. **`check_python_version`** — sanity-check that Python ≥ 3.8.
4. **`install_west`** — `pip install west pyelftools` into the venv if needed.
5. **`prepare_<device>`** — the per-variant routine:
   - `git clone --recurse-submodules -b <branch> …/from-urob-zmk-config.git`
   - symlink `config/west.yml` and `build.yaml` into the workspace root,
   - `west init -l config` + `west update` (downloads ZMK, Zephyr, modules),
   - `west zephyr-export` (registers this Zephyr in `~/.cmake/packages/Zephyr`),
   - `pip install -r zephyr/scripts/requirements.txt`.

### Examples

```bash
# Advantage360 Pro into a dedicated folder
./prepare_zmk_build_environment.sh -d adv360-pro -p ~/kb/adv360

# Eyelash Corne touchpad, forcing a newer Python (only needed for Zephyr 4.x stacks)
./prepare_zmk_build_environment.sh -d eyelash_corne_touchpad -p ~/kb/eyelash_tp --python python3.12
```

---

## `build_urob_zmk.sh`

Compiles every `board` + `shield` combination listed in the workspace's
`build.yaml` and copies the resulting firmware into an output folder under this
script's directory. It runs the **local** (non-Docker) build path of
`from-urob-zmk-config/scripts/zmk_build.sh`.

### Usage

```text
build_urob_zmk.sh [-h] [-p PATH] [-o OUTPUT_NAME] [-f] [-l]
```

### Options

| Option | Argument | Description |
| --- | --- | --- |
| `-h`, `--help` | — | Show help and exit. |
| `-p`, `--path` | `PATH` | The workspace previously set up by `prepare_zmk_build_environment.sh`. **Required.** |
| `-o`, `--output-name` | `NAME` | Output sub-directory name (under this script's directory) for the `.uf2`/`.bin` files. Default: `output_uf2`. Use a per-variant name to avoid clobbering other variants' firmware. |
| `-f`, `--force` | — | Force a clean rebuild (passes pristine `-p` to `west build`). |
| `-l`, `--zmk-logging` | — | Build with the `zmk-usb-logging` snippet enabled (USB serial logging). |

### What it does (in order)

1. Activate the workspace `.venv` (from `-p PATH`); abort if no venv is found.
2. Resolve `SOURCE_DIR`, `CONFIG_DIR` (`…/from-urob-zmk-config`), `ZMK_DIR`
   (`…/zmk`) and `ZEPHYR_DIR` (`…/zephyr`); read the Zephyr version from
   `zephyr/VERSION`.
3. **Export `ZEPHYR_BASE=$ZEPHYR_DIR`** — pins `find_package(Zephyr)` to *this*
   workspace's Zephyr so the shared `~/.cmake/packages/Zephyr` registry can't
   accidentally resolve to a different variant's Zephyr.
4. `west zephyr-export`, then invoke
   `from-urob-zmk-config/scripts/zmk_build.sh -l` with the host config/zmk dirs
   and (optionally) `-p` for force and `-S zmk-usb-logging` for logging.
5. Copy each built `zmk.uf2`/`zmk.bin` into
   `./<output-name>/<board>_<shield>-zmk.uf2`, backing up any previous file to
   `*.bak`.

### Examples

```bash
# Standard build (firmware -> ./output_uf2/)
./build_urob_zmk.sh -p ~/kb/adv360

# Per-variant output folder + clean rebuild + USB logging
./build_urob_zmk.sh -p ~/kb/eyelash_tp -o output_uf2_eyelash_corne_touchpad -f -l
```

---

## How a prepared workspace is structured

After `prepare_*`, the `-p` directory looks like this (a standard west
workspace plus the symlinks the build expects):

```text
<workspace>/
├── .venv/                     # per-workspace Python virtual environment
├── .west/                     # west workspace marker
├── build.yaml   -> from-urob-zmk-config/build.yaml
├── config/
│   └── west.yml -> ../from-urob-zmk-config/config/west.yml   # the manifest
├── from-urob-zmk-config/      # the cloned, variant-specific config repo
│   ├── boards/                # out-of-tree board definitions
│   ├── config/                # keymaps, *.conf, combos.dtsi …
│   ├── build.yaml             # list of board/shield combos to build
│   └── scripts/zmk_build.sh   # the lower-level builder these scripts call
├── zmk/                       # ZMK firmware source (the west "app")
├── zephyr/                    # Zephyr RTOS (version selected by the manifest)
├── modules/                   # Zephyr/ZMK modules pulled by `west update`
└── zmk-helpers, zmk-nice-oled, …  # extra modules from the manifest
```

---

## Output firmware

- Files are written to `<this-script-dir>/<output-name>/` (default `output_uf2/`).
- Naming: `<board>_<shield>-zmk.uf2` (or `.bin` when no UF2 is produced).
- Re-running a build moves an existing same-named artifact to `<name>.bak`
  before copying the fresh one.
- Per-board build logs are written to `/tmp/zmk_build_<board>.log`.

For example, the `eyelash_corne_touchpad` build produces:

```text
output_uf2_eyelash_corne_touchpad/
├── eyelash_corne_left_nice_epaper-zmk.uf2
├── eyelash_corne_left_nice_epaper_new-zmk.uf2
├── eyelash_corne_left_settings_reset-zmk.uf2
└── eyelash_corne_right_nice_view_custom-zmk.uf2
```

---

## Worked example: the `eyelash_corne_touchpad` variant

This variant was added by branching from `eyelash_corne` and wiring it through
both scripts. The full recipe (reproducible from scratch):

1. **Create the branch** on `from-urob-zmk-config` from `eyelash_corne`:

   ```bash
   git push origin refs/remotes/origin/eyelash_corne:refs/heads/eyelash_corne_touchpad
   ```

2. **Prepare** the workspace:

   ```bash
   ./prepare_zmk_build_environment.sh -d eyelash_corne_touchpad \
       -p .../Eyelash-Corne-Touchpad/source_urob_zmk_eyelash_corne_touchpad
   ```

3. **Build** into a dedicated output folder:

   ```bash
   ./build_urob_zmk.sh \
       -p .../Eyelash-Corne-Touchpad/source_urob_zmk_eyelash_corne_touchpad \
       -o output_uf2_eyelash_corne_touchpad
   ```

The branch's `config/west.yml` pins ZMK and the helper modules to the
**known-good Zephyr 3.5 stack** (see below), which is what makes the build
reproducible.

---

## Versioning & reproducibility (important)

The `eyelash_corne` family of boards uses the **older Zephyr board model** and
only builds against **Zephyr `v3.5.0+zmk-fixes`** (ZMK as of April 2025). The
upstream `zmk`, `zmk-helpers`, etc. branches have since moved to **Zephyr 4.x**,
whose new board model breaks these boards with errors such as:

```text
Kconfig/soc/Kconfig.defconfig not found (in 'source "$(KCONFIG_BINARY_DIR)/soc/Kconfig.defconfig"')
Could NOT find Python3: Found unsuitable version "3.9.x", but required is at least "3.10"
```

To stay reproducible, the `eyelash_corne_touchpad` branch's manifest
(`config/west.yml`) **pins every project to a fixed commit** instead of tracking
a moving branch:

| Project | Pinned revision |
| --- | --- |
| `zmk` | `6f85f48b19afae04f98e9abacb36ce1425b61f78` (imports Zephyr `v3.5.0+zmk-fixes`) |
| `zmk-helpers` | `8d7e79731803c961bae61f6fc8ffa3a35a62e5eb` |
| `zmk-tri-state` | `ebbc1f0ccdb51669650bb0ac3e34920d09e62400` |
| `mario-peripheral-animation` | `1aa3950d6c86b4240b3f79d06bdbb04c5d920711` |
| `zmk-nice-oled` | `ff9969d3fdd49cb9a3a8ee3934b96781f2265aee` |

Because that stack targets Zephyr 3.5, the venv uses **Python 3.9** (the default).
If you ever intentionally bump these pins to a Zephyr 4.x stack, also prepare the
workspace with `--python python3.12` (or any ≥ 3.10).

> The same pinning discipline applies to the other variants: when their upstream
> branches drift onto an incompatible Zephyr, pin the manifest to a known-good
> commit set rather than chasing `main`.

---

## Troubleshooting

For full root-cause analysis of the issues below (with logs, investigation steps
and the reasoning behind each fix), see
[`docs/ZMK_Corne_Problems_And_Solutions.md`](docs/ZMK_Corne_Problems_And_Solutions.md).

| Symptom | Likely cause / fix |
| --- | --- |
| `Could NOT find Python3 … required is at least "3.10"` | The Zephyr in the workspace is 4.x. Either pin the manifest back to Zephyr 3.5, or re-prepare with `--python python3.12`. |
| `Kconfig/soc/Kconfig.defconfig not found` | Zephyr 4.x pulled into an old-board-model variant. Pin the manifest to the known-good Zephyr 3.5 commits (see above) and re-run `west update`. |
| Build picks the **wrong** Zephyr (another variant's) | Several workspaces are registered in `~/.cmake/packages/Zephyr`. `build_urob_zmk.sh` exports `ZEPHYR_BASE` to force the correct one — make sure you're running the build via the script, not a bare `west build`. |
| `No path specified` | Both scripts require `-p`. |
| `Neither .venv directory found nor Python virtual environment` (build) | Run `prepare_zmk_build_environment.sh` for that `-p` path first. |
| Re-prepare doesn't update sources | `prepare_*` skips `west update` when `zmk/` already exists. To re-sync after changing the manifest, run `west update` inside the activated workspace venv. |
