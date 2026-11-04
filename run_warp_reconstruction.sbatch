#!/bin/bash

set -euo pipefail

# Optional private site initialization (environment modules, conda, library paths).
if [[ -n "${CLUSTER_INIT:-}" ]]; then
    [[ -f "$CLUSTER_INIT" ]] || { echo "ERROR: missing CLUSTER_INIT: $CLUSTER_INIT" >&2; exit 1; }
    # shellcheck disable=SC1090
    source "$CLUSTER_INIT"
fi

# Guard deletion of generated paths in this stage. Never allow a cleanup target
# to leave the dedicated run directory, including through an existing symlink.
safe_rm_generated() {
    local path
    for path in "$@"; do safe_generated_path "$path"; done
    rm -rf -- "$@"
}

safe_generated_path() {
    local path="$1" real_build real_parent
    real_build="$(cd "${BUILD:?BUILD is required}" && pwd -P)"
    [[ "$path" == "$real_build/"* ]] || { echo "ERROR: cleanup path outside RUN_DIR: $path" >&2; exit 1; }
    real_parent="$(realpath -m "$(dirname "$path")")"
    [[ "$real_parent" == "$real_build" || "$real_parent" == "$real_build/"* ]] || {
        echo "ERROR: cleanup path resolves outside RUN_DIR: $path" >&2; exit 1;
    }
}

export LC_ALL=C
export LANG=C

if [[ "$#" -eq 0 ]]; then
    echo "ERROR: no datasets were passed to run_warp_reconstruction.sbatch"
    exit 1
fi
DATASETS=("$@")

echo
echo "============================================================"
echo "Warp reconstruction job"
echo "============================================================"
echo "Start time: $(date)"
echo "Host:       $(hostname)"
echo "Work dir:   $(pwd)"
echo
echo "Datasets:"
printf '  %s\n' "${DATASETS[@]}"
echo

nvidia-smi || true
echo

###############################################################################
# Required inputs from pipeline controller
###############################################################################

: "${WARPTOOLS_ENV:?ERROR: WARPTOOLS_ENV is not set}"
: "${WARP_RECON_INPUT:?ERROR: WARP_RECON_INPUT is not set}"
: "${WARP_RECON_OUTPUT:?ERROR: WARP_RECON_OUTPUT is not set}"
: "${WARP_RECON_MISSALIGN_PROJECT:?ERROR: WARP_RECON_MISSALIGN_PROJECT is not set}"
: "${WARP_RECON_SETTINGS:?ERROR: WARP_RECON_SETTINGS is not set}"
: "${WARP_RECON_INPUT_PROCESSING:?ERROR: WARP_RECON_INPUT_PROCESSING is not set}"
: "${WARP_RECON_TOMOSTAR:?ERROR: WARP_RECON_TOMOSTAR is not set}"
: "${WARP_RECON_CTF_OUTPUT:?ERROR: WARP_RECON_CTF_OUTPUT is not set}"
: "${WARP_RECON_TOMO_OUTPUT:?ERROR: WARP_RECON_TOMO_OUTPUT is not set}"
: "${WARP_RECON_ANGPIX:?ERROR: WARP_RECON_ANGPIX is not set}"
: "${WARP_RECON_RUN_CTF:?ERROR: WARP_RECON_RUN_CTF is not set}"
: "${WARP_CTF_RANGE_HIGH:?ERROR: WARP_CTF_RANGE_HIGH is not set}"
: "${WARP_CTF_DEFOCUS_MAX:?ERROR: WARP_CTF_DEFOCUS_MAX is not set}"
: "${WARP_RECON_PERDEVICE:?ERROR: WARP_RECON_PERDEVICE is not set}"
: "${WARP_RECON_HALF_MAPS:?ERROR: WARP_RECON_HALF_MAPS is not set}"
: "${WARP_RECON_FORCE_FLOAT32:?ERROR: WARP_RECON_FORCE_FLOAT32 is not set}"
: "${WARP_RECON_DONT_INVERT:?ERROR: WARP_RECON_DONT_INVERT is not set}"

: "${MISSALIGN_INPUT:-}"
: "${ISONET2_ENV:-}"

WARPTOOLS_BIN="$WARPTOOLS_ENV/bin/WarpTools"

[[ -x "$WARPTOOLS_BIN" ]] || { echo "ERROR: WarpTools binary not executable: $WARPTOOLS_BIN"; exit 1; }
[[ -f "$WARP_RECON_SETTINGS" ]] || { echo "ERROR: missing settings file: $WARP_RECON_SETTINGS"; exit 1; }
[[ -d "$WARP_RECON_INPUT_PROCESSING" ]] || { echo "ERROR: missing Warp tiltseries folder: $WARP_RECON_INPUT_PROCESSING"; exit 1; }
[[ -d "$WARP_RECON_TOMOSTAR" ]] || { echo "ERROR: missing tomostar folder: $WARP_RECON_TOMOSTAR"; exit 1; }

mkdir -p "$WARP_RECON_OUTPUT" "$WARP_RECON_CTF_OUTPUT" "$WARP_RECON_TOMO_OUTPUT"

###############################################################################
# TMPDIR
###############################################################################

LONG_TMPDIR="$WARP_RECON_OUTPUT/tmp"
mkdir -p "$LONG_TMPDIR"

SHORT_TMPDIR="${SCRATCH_SYMLINK_PARENT:-/tmp}/${USER}_warp_recon_${SLURM_JOB_ID:-$$}"
if [[ -e "$SHORT_TMPDIR" || -L "$SHORT_TMPDIR" ]]; then
    echo "ERROR: scratch link already exists; inspect manually: $SHORT_TMPDIR" >&2
    exit 1
fi
ln -s "$LONG_TMPDIR" "$SHORT_TMPDIR"

export TMPDIR="$SHORT_TMPDIR"
export TMP="$SHORT_TMPDIR"
export TEMP="$SHORT_TMPDIR"

echo "TMPDIR: $TMPDIR -> $LONG_TMPDIR"
echo

###############################################################################
# Paths
###############################################################################

AVERAGE_DIR="$WARP_RECON_MISSALIGN_PROJECT/warp_frameseries/average"

SPLIT_ROOT="$WARP_RECON_INPUT/split_from_aretomo"
SPLIT_EVN_DIR="$SPLIT_ROOT/EVN"
SPLIT_ODD_DIR="$SPLIT_ROOT/ODD"

FULL_AVERAGE_BACKUP="$WARP_RECON_INPUT/full_average_backup_from_missalignment"

EVN_OUTPUT="$WARP_RECON_OUTPUT/tomograms_EVN"
ODD_OUTPUT="$WARP_RECON_OUTPUT/tomograms_ODD"

echo "Paths:"
echo "  WARP_RECON_INPUT:             $WARP_RECON_INPUT"
echo "  WARP_RECON_OUTPUT:            $WARP_RECON_OUTPUT"
echo "  WARP_RECON_MISSALIGN_PROJECT: $WARP_RECON_MISSALIGN_PROJECT"
echo "  AVERAGE_DIR:                  $AVERAGE_DIR"
echo "  full output:                  $WARP_RECON_TOMO_OUTPUT"
echo "  EVN output:                   $EVN_OUTPUT"
echo "  ODD output:                   $ODD_OUTPUT"
echo "  split root:                   $SPLIT_ROOT"
echo

###############################################################################
# Helpers
###############################################################################

restore_full_average() {
    if [[ -d "$FULL_AVERAGE_BACKUP" ]]; then
        echo
        echo "Restoring original MissAlignment full average folder:"
        echo "  $AVERAGE_DIR"
        safe_rm_generated "$AVERAGE_DIR"
        mkdir -p "$AVERAGE_DIR"
        cp -a "$FULL_AVERAGE_BACKUP"/. "$AVERAGE_DIR"/
    fi
}

use_average_set() {
    local label="$1"
    local src_dir="$2"

    [[ -d "$src_dir" ]] || { echo "ERROR: missing average source folder: $src_dir"; exit 1; }

    echo
    echo "Switching active Warp average folder to: $label"
    echo "  source: $src_dir"
    echo "  active: $AVERAGE_DIR"

    safe_rm_generated "$AVERAGE_DIR"
    mkdir -p "$AVERAGE_DIR"
    cp -a "$src_dir"/. "$AVERAGE_DIR"/

    echo "Active average examples:"
    find "$AVERAGE_DIR" -maxdepth 1 -type f -name "*.mrc" | sort | sed -n '1,8p'
    echo
}

run_ts_reconstruct() {
    local label="$1"
    local output_processing="$2"

    echo
    echo "============================================================"
    echo "Running WarpTools ts_reconstruct: $label"
    echo "============================================================"
    echo "  settings:          $WARP_RECON_SETTINGS"
    echo "  input_processing:  $RECON_INPUT_PROCESSING"
    echo "  output_processing: $output_processing"
    echo

    safe_rm_generated "$output_processing"
    mkdir -p "$output_processing"

    RECON_ARGS=(
      ts_reconstruct
      --settings "$WARP_RECON_SETTINGS"
      --input_processing "$RECON_INPUT_PROCESSING"
      --output_processing "$output_processing"
      --angpix "$WARP_RECON_ANGPIX"
      --perdevice "$WARP_RECON_PERDEVICE"
    )

    if [[ "$WARP_RECON_DONT_INVERT" -eq 1 ]]; then
        RECON_ARGS+=(--dont_invert)
    fi

    if [[ "$WARP_RECON_FORCE_FLOAT32" -eq 1 ]]; then
        export WARP_FORCE_MRC_FLOAT32=1
        echo "WARP_FORCE_MRC_FLOAT32=1"
    fi

    echo "Command:"
    printf '  %q' "$WARPTOOLS_BIN" "${RECON_ARGS[@]}"
    echo
    echo

    "$WARPTOOLS_BIN" "${RECON_ARGS[@]}"
}

add_label_to_reconstruction_files() {
    local recon_dir="$1"
    local label="$2"

    [[ -d "$recon_dir" ]] || { echo "ERROR: missing reconstruction folder: $recon_dir"; exit 1; }

    echo
    echo "Adding _$label label to reconstructed files in:"
    echo "  $recon_dir"

    find "$recon_dir" -maxdepth 1 -type f \( -name "*.mrc" -o -name "*.png" \) -print0 \
      | while IFS= read -r -d '' f; do
            base="$(basename "$f")"
            stem="${base%.*}"
            ext="${base##*.}"

            if [[ "$stem" == *"_$label" ]]; then
                continue
            fi

            mv -f "$f" "$recon_dir/${stem}_${label}.${ext}"
        done

    echo "Labeled reconstruction files:"
    find "$recon_dir" -maxdepth 1 -type f \( -name "*.mrc" -o -name "*.png" \) | sort
    echo
}

###############################################################################
# Prepare EVN/ODD split tilt images
###############################################################################

prepare_evn_odd_splits_and_backup_full() {
    [[ -d "$AVERAGE_DIR" ]] || { echo "ERROR: missing original Warp average folder: $AVERAGE_DIR"; exit 1; }

    safe_rm_generated "$SPLIT_ROOT" "$FULL_AVERAGE_BACKUP"
    mkdir -p "$SPLIT_EVN_DIR" "$SPLIT_ODD_DIR" "$FULL_AVERAGE_BACKUP"

    # Backup the already-existing MissAlignment/Warp full per-tilt average images.
    # We do NOT split the full AreTomo3 stack again.
    cp -a "$AVERAGE_DIR"/. "$FULL_AVERAGE_BACKUP"/

    if [[ "$WARP_RECON_HALF_MAPS" -ne 1 ]]; then
        echo "WARP_RECON_HALF_MAPS=0, not preparing EVN/ODD split inputs."
        return
    fi

    echo
    echo "============================================================"
    echo "Splitting AreTomo3 EVN/ODD stacks into input_warp_reconstruction"
    echo "============================================================"

    [[ -n "${MISSALIGN_INPUT:-}" ]] || { echo "ERROR: MISSALIGN_INPUT is required"; exit 1; }
    [[ -d "$MISSALIGN_INPUT" ]] || { echo "ERROR: missing MISSALIGN_INPUT: $MISSALIGN_INPUT"; exit 1; }
    [[ -n "${ISONET2_ENV:-}" ]] || { echo "ERROR: ISONET2_ENV is required for Python/mrcfile"; exit 1; }
    [[ -x "$ISONET2_ENV/bin/python" ]] || { echo "ERROR: missing Python: $ISONET2_ENV/bin/python"; exit 1; }

    export MISSALIGN_INPUT
    export FULL_AVERAGE_BACKUP
    export SPLIT_EVN_DIR
    export SPLIT_ODD_DIR

    "$ISONET2_ENV/bin/python" - "${DATASETS[@]}" <<'PY'
from pathlib import Path
import os
import sys
import numpy as np
import mrcfile

if len(sys.argv) < 2:
    raise SystemExit("ERROR: no datasets supplied to EVN/ODD splitter")

datasets = sys.argv[1:]
if len(set(datasets)) != len(datasets):
    raise SystemExit(f"ERROR: duplicate dataset names were supplied: {datasets}")

missalign_input = Path(os.environ["MISSALIGN_INPUT"])
full_average_backup = Path(os.environ["FULL_AVERAGE_BACKUP"])
split_evn_dir = Path(os.environ["SPLIT_EVN_DIR"])
split_odd_dir = Path(os.environ["SPLIT_ODD_DIR"])


def identify_dataset(stem: str):
    matches = [
        dataset
        for dataset in datasets
        if stem == dataset or stem.startswith(dataset + "_")
    ]
    if not matches:
        return None
    longest = max(len(dataset) for dataset in matches)
    winners = [dataset for dataset in matches if len(dataset) == longest]
    if len(winners) != 1:
        raise SystemExit(
            f"ERROR: ambiguous dataset mapping for filename stem {stem}: {winners}"
        )
    return winners[0]


all_full_files = sorted(full_average_backup.glob("*_tilt_*.mrc"))
unexpected_full = [
    path for path in all_full_files if identify_dataset(path.stem) is None
]
if unexpected_full:
    raise SystemExit(
        "ERROR: full-average backup contains files outside the current DATASETS list: "
        + ", ".join(str(path) for path in unexpected_full[:20])
    )

counts = {"EVN": 0, "ODD": 0}
expected_full_count = 0

for dataset in datasets:
    ds_dir = missalign_input / dataset
    if not ds_dir.is_dir():
        raise SystemExit(f"ERROR: selected MissAlignment input folder is missing: {ds_dir}")

    # Use existing MissAlignment-prepared full average filenames as the template.
    # This is only naming/order reference; the full stack is not split again.
    full_names = sorted(full_average_backup.glob(f"{dataset}_tilt_*.mrc"))

    if not full_names:
        sys.exit(f"ERROR: no full average tilt images found for {dataset} in {full_average_backup}")
    expected_full_count += len(full_names)

    for label, stack_name, out_dir in [
        ("EVN", "even.mrc", split_evn_dir),
        ("ODD", "odd.mrc",  split_odd_dir),
    ]:
        stack_path = ds_dir / stack_name

        if not stack_path.exists():
            sys.exit(f"ERROR: missing {label} AreTomo3 tilt stack: {stack_path}")

        with mrcfile.mmap(stack_path, permissive=True) as m:
            data = m.data

            if data.ndim != 3:
                sys.exit(f"ERROR: expected 3D stack for {stack_path}, got shape {data.shape}")

            if data.shape[0] != len(full_names):
                sys.exit(
                    f"ERROR: {stack_path} has {data.shape[0]} slices, "
                    f"but {len(full_names)} full average tilt images were found for {dataset}"
                )

            for i, full_file in enumerate(full_names):
                out_path = out_dir / full_file.name
                arr = np.asarray(data[i], dtype=np.float32)

                with mrcfile.new(out_path, overwrite=True) as out:
                    out.set_data(arr)
                    try:
                        out.voxel_size = m.voxel_size
                    except Exception:
                        pass

                counts[label] += 1

if len(all_full_files) != expected_full_count:
    raise SystemExit(
        f"ERROR: full-average identity check failed: found {len(all_full_files)} total "
        f"files but selected datasets account for {expected_full_count}"
    )

print("Generated split tilt images:")
print(f"  selected datasets: {datasets}")
print(f"  full template images: {expected_full_count}")
print(f"  EVN: {counts['EVN']} files -> {split_evn_dir}")
print(f"  ODD: {counts['ODD']} files -> {split_odd_dir}")
PY

    echo
    echo "Full backup examples:"
    find "$FULL_AVERAGE_BACKUP" -maxdepth 1 -type f -name "*.mrc" | sort | sed -n '1,8p'
    echo
    echo "EVN split examples:"
    find "$SPLIT_EVN_DIR" -maxdepth 1 -type f -name "*.mrc" | sort | sed -n '1,8p'
    echo
    echo "ODD split examples:"
    find "$SPLIT_ODD_DIR" -maxdepth 1 -type f -name "*.mrc" | sort | sed -n '1,8p'
    echo
}

###############################################################################
# CTF estimation using original full project
###############################################################################

RECON_INPUT_PROCESSING="$WARP_RECON_INPUT_PROCESSING"

if [[ "$WARP_RECON_RUN_CTF" -eq 1 ]]; then
    echo
    echo "============================================================"
    echo "Running WarpTools ts_ctf on original full project"
    echo "============================================================"

    safe_rm_generated "$WARP_RECON_CTF_OUTPUT"
    mkdir -p "$WARP_RECON_CTF_OUTPUT"

    "$WARPTOOLS_BIN" ts_ctf \
      --settings "$WARP_RECON_SETTINGS" \
      --input_processing "$WARP_RECON_INPUT_PROCESSING" \
      --output_processing "$WARP_RECON_CTF_OUTPUT" \
      --range_high "$WARP_CTF_RANGE_HIGH" \
      --defocus_max "$WARP_CTF_DEFOCUS_MAX" \
      --perdevice "$WARP_RECON_PERDEVICE"

    RECON_INPUT_PROCESSING="$WARP_RECON_CTF_OUTPUT"
else
    echo "WARP_RECON_RUN_CTF=0, skipping WarpTools ts_ctf."
fi

###############################################################################
# Reconstruction
###############################################################################

prepare_evn_odd_splits_and_backup_full
trap restore_full_average EXIT

safe_rm_generated "$WARP_RECON_TOMO_OUTPUT" "$EVN_OUTPUT" "$ODD_OUTPUT"
mkdir -p "$WARP_RECON_TOMO_OUTPUT"

# Full reconstruction uses the original MissAlignment-prepared full averages.
use_average_set "FULL from MissAlignment" "$FULL_AVERAGE_BACKUP"
run_ts_reconstruct "FULL, original MissAlignment-prepared full tilt images" "$WARP_RECON_TOMO_OUTPUT"

if [[ "$WARP_RECON_HALF_MAPS" -eq 1 ]]; then
    # EVN reconstruction uses AreTomo3 EVN split images, same MissAlignment alignment.
    use_average_set "EVN from AreTomo3 EVN stack" "$SPLIT_EVN_DIR"
    run_ts_reconstruct "EVN, AreTomo3 EVN stack + MissAlignment refined alignment" "$EVN_OUTPUT"
    add_label_to_reconstruction_files "$EVN_OUTPUT/reconstruction" "EVN"

    # ODD reconstruction uses AreTomo3 ODD split images, same MissAlignment alignment.
    use_average_set "ODD from AreTomo3 ODD stack" "$SPLIT_ODD_DIR"
    run_ts_reconstruct "ODD, AreTomo3 ODD stack + MissAlignment refined alignment" "$ODD_OUTPUT"
    add_label_to_reconstruction_files "$ODD_OUTPUT/reconstruction" "ODD"
fi

restore_full_average
trap - EXIT

###############################################################################
# Validation
###############################################################################

echo
echo "Validation:"

export WARP_RECON_TOMO_OUTPUT EVN_OUTPUT ODD_OUTPUT WARP_RECON_CTF_OUTPUT
export WARP_RECON_HALF_MAPS WARP_RECON_RUN_CTF

"$ISONET2_ENV/bin/python" - "${DATASETS[@]}" <<'PY_VALIDATE'
from pathlib import Path
import os
import sys

if len(sys.argv) < 2:
    raise SystemExit("ERROR: no datasets supplied to Warp output validator")

datasets = sys.argv[1:]
if len(set(datasets)) != len(datasets):
    raise SystemExit(f"ERROR: duplicate dataset names were supplied: {datasets}")

full_dir = Path(os.environ["WARP_RECON_TOMO_OUTPUT"]) / "reconstruction"
evn_dir = Path(os.environ["EVN_OUTPUT"]) / "reconstruction"
odd_dir = Path(os.environ["ODD_OUTPUT"]) / "reconstruction"
ctf_dir = Path(os.environ["WARP_RECON_CTF_OUTPUT"])
half_maps = int(os.environ["WARP_RECON_HALF_MAPS"])
run_ctf = int(os.environ["WARP_RECON_RUN_CTF"])


def identify_dataset(stem: str):
    matches = [
        dataset
        for dataset in datasets
        if stem == dataset or stem.startswith(dataset + "_")
    ]
    if not matches:
        return None
    longest = max(len(dataset) for dataset in matches)
    winners = [dataset for dataset in matches if len(dataset) == longest]
    if len(winners) != 1:
        raise SystemExit(
            f"ERROR: ambiguous dataset mapping for filename stem {stem}: {winners}"
        )
    return winners[0]


def audit_recon(folder: Path, label: str, suffix: str | None):
    if not folder.is_dir():
        raise SystemExit(f"ERROR: missing {label} reconstruction folder: {folder}")

    mapping = {dataset: [] for dataset in datasets}
    unexpected = []

    for path in sorted(folder.glob("*.mrc")):
        stem = path.stem
        if suffix is not None:
            if not stem.endswith(suffix):
                unexpected.append(path)
                continue
            stem = stem[:-len(suffix)]
        dataset = identify_dataset(stem)
        if dataset is None:
            unexpected.append(path)
        else:
            mapping[dataset].append(path)

    if unexpected:
        raise SystemExit(
            f"ERROR: unexpected {label} reconstruction files: "
            + ", ".join(str(path) for path in unexpected)
        )

    bad = {
        dataset: paths
        for dataset, paths in mapping.items()
        if len(paths) != 1
    }
    if bad:
        details = "; ".join(
            f"{dataset} -> {[str(path) for path in paths]}"
            for dataset, paths in bad.items()
        )
        raise SystemExit(
            f"ERROR: expected exactly one {label} tomogram for every selected dataset: "
            + details
        )

    print(f"  {label}: exact dataset identity check passed")
    for dataset in datasets:
        print(f"    {dataset}: {mapping[dataset][0]}")


audit_recon(full_dir, "FULL", None)
if half_maps == 1:
    audit_recon(evn_dir, "EVN", "_EVN")
    audit_recon(odd_dir, "ODD", "_ODD")

if run_ctf == 1:
    xml_names = {path.stem for path in ctf_dir.glob("*.xml")}
    expected = set(datasets)
    if xml_names != expected:
        raise SystemExit(
            f"ERROR: Warp CTF XML dataset identities do not match. "
            f"expected={sorted(expected)}, found={sorted(xml_names)}"
        )
    print("  CTF XML: exact dataset identity check passed")

print("OK: Warp outputs match the pipeline DATASETS list exactly.")
PY_VALIDATE

if [[ "$WARP_RECON_HALF_MAPS" -eq 1 ]]; then
    split_evn_count=$(find "$SPLIT_EVN_DIR" -maxdepth 1 -type f -name "*.mrc" 2>/dev/null | wc -l)
    split_odd_count=$(find "$SPLIT_ODD_DIR" -maxdepth 1 -type f -name "*.mrc" 2>/dev/null | wc -l)
    echo "  split EVN tilt images: $split_evn_count"
    echo "  split ODD tilt images: $split_odd_count"
fi

echo
echo "============================================================"
echo "Warp reconstruction finished"
echo "End time: $(date)"
echo "============================================================"
echo

echo "Split input overview:"
find "$SPLIT_ROOT" -maxdepth 2 -type f -name "*.mrc" 2>/dev/null | sort | sed -n '1,80p'
echo

echo "Final output overview:"
find "$WARP_RECON_OUTPUT" -maxdepth 4 -type f -name "*.mrc" 2>/dev/null | sort
