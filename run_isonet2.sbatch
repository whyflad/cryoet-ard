#!/usr/bin/env bash

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

###############################################################################
# IsoNet2 multi-stage denoising/correction workflow
#
#   prepare_star with full/even/odd tomograms
#   patch per-tomogram defocus and final tilt range from Warp CTF XML
#   initial Refine: mw_weight 20, cube size 96, network CTF, B-factor 0
#   Predict all tomograms
#   make_mask: density 50, std 50, z_crop 0.2
#   final Refine: mw_weight 200, cube size 128, network CTF, B-factor 0,
#                 100 epochs
#   final Predict all tomograms
###############################################################################

if [[ "$#" -lt 1 ]]; then
    echo "ERROR: no datasets were passed from the pipeline controller." >&2
    echo "Usage: sbatch run_isonet2.sbatch DATASET [DATASET ...]" >&2
    exit 1
fi

DATASETS=("$@")

###############################################################################
# Paths
###############################################################################

: "${BUILD:?ERROR: BUILD is required (launch through pipeline.sh)}"
BASE="${BASE:-$(dirname "$BUILD")}" 

ISONET2_ROOT="${ISONET2_ROOT:-$BASE/isonet2}"
ISONET2_ENV="${ISONET2_ENV:-$ISONET2_ROOT/source/build/conda_env}"
ISONET2_BIN="${ISONET2_BIN:-$ISONET2_ENV/bin/isonet.py}"

WARP_RECON_OUTPUT="${WARP_RECON_OUTPUT:-$BUILD/output_warp_reconstruction}"
ISONET2_WARP_CTF_DIR="${ISONET2_WARP_CTF_DIR:-$WARP_RECON_OUTPUT/ctf}"

ISONET2_INPUT="${ISONET2_INPUT:-$BUILD/input_isonet2}"
ISONET2_OUTPUT="${ISONET2_OUTPUT:-$BUILD/output_isonet2}"
ISONET2_STAR="${ISONET2_STAR:-$ISONET2_OUTPUT/tomograms.star}"
ISONET2_METADATA_JSON="$ISONET2_OUTPUT/detected_warp_metadata.json"

ISONET2_FULL_INPUT="${ISONET2_FULL_INPUT:-$ISONET2_INPUT/full}"
ISONET2_EVN_INPUT="${ISONET2_EVN_INPUT:-$ISONET2_INPUT/EVN}"
ISONET2_ODD_INPUT="${ISONET2_ODD_INPUT:-$ISONET2_INPUT/ODD}"

FULL_RECON_DIR="$WARP_RECON_OUTPUT/tomograms/reconstruction"
EVN_RECON_DIR="$WARP_RECON_OUTPUT/tomograms_EVN/reconstruction"
ODD_RECON_DIR="$WARP_RECON_OUTPUT/tomograms_ODD/reconstruction"

INITIAL_REFINE_DIR="$ISONET2_OUTPUT/initial_refine"
INITIAL_PREDICT_DIR="$ISONET2_OUTPUT/initial_corrected_tomos"
MASK_DIR="$ISONET2_OUTPUT/mask"
FINAL_REFINE_DIR="$ISONET2_OUTPUT/final_refine"
FINAL_PREDICT_DIR="$ISONET2_OUTPUT/corrected_tomos"

###############################################################################
# Parameters
###############################################################################

ISONET2_RUN_PREPARE_STAR="${ISONET2_RUN_PREPARE_STAR:-1}"
ISONET2_RUN_INITIAL_REFINE="${ISONET2_RUN_INITIAL_REFINE:-1}"
ISONET2_RUN_INITIAL_PREDICT="${ISONET2_RUN_INITIAL_PREDICT:-1}"
ISONET2_RUN_MAKE_MASK="${ISONET2_RUN_MAKE_MASK:-1}"
ISONET2_RUN_FINAL_REFINE="${ISONET2_RUN_FINAL_REFINE:-1}"
ISONET2_RUN_FINAL_PREDICT="${ISONET2_RUN_FINAL_PREDICT:-1}"

ISONET2_GPU_ID="${ISONET2_GPU_ID:-0,1,2,3}"
ISONET2_NCPUS="${ISONET2_NCPUS:-32}"
ISONET2_ARCH="${ISONET2_ARCH:-unet-medium}"
ISONET2_BATCH_SIZE="${ISONET2_BATCH_SIZE:-auto}"
ISONET2_METHOD="${ISONET2_METHOD:-isonet2-n2n}"
ISONET2_CTF_MODE="${ISONET2_CTF_MODE:-network}"
ISONET2_BFACTOR="${ISONET2_BFACTOR:-0}"

ISONET2_PIXEL_SIZE="${ISONET2_PIXEL_SIZE:-9.184}"
ISONET2_CS="${ISONET2_CS:-2.7}"
ISONET2_VOLTAGE="${ISONET2_VOLTAGE:-300}"
ISONET2_AC="${ISONET2_AC:-0.1}"
ISONET2_NUMBER_SUBTOMOS="${ISONET2_NUMBER_SUBTOMOS:-100}"
ISONET2_CLEAN_STAGE_OUTPUTS="${ISONET2_CLEAN_STAGE_OUTPUTS:-1}"

# Fail rather than silently substitute a defocus when the enabled tilt closest
# to zero is a strong outlier relative to nearby enabled tilts.
ISONET2_CTF_NEIGHBOR_COUNT="${ISONET2_CTF_NEIGHBOR_COUNT:-4}"
ISONET2_CTF_MAX_DEVIATION_UM="${ISONET2_CTF_MAX_DEVIATION_UM:-0.75}"
ISONET2_CTF_MAX_DEVIATION_FRACTION="${ISONET2_CTF_MAX_DEVIATION_FRACTION:-0.20}"

# Configurable initial Refine epochs; validate for your data.
ISONET2_INITIAL_REFINE_CUBE_SIZE="${ISONET2_INITIAL_REFINE_CUBE_SIZE:-96}"
ISONET2_INITIAL_REFINE_EPOCHS="${ISONET2_INITIAL_REFINE_EPOCHS:-50}"
ISONET2_INITIAL_REFINE_MW_WEIGHT="${ISONET2_INITIAL_REFINE_MW_WEIGHT:-20}"

ISONET2_MASK_INPUT_COLUMN="${ISONET2_MASK_INPUT_COLUMN:-rlnCorrectedTomoName}"
ISONET2_MASK_DENSITY_PERCENTAGE="${ISONET2_MASK_DENSITY_PERCENTAGE:-50}"
ISONET2_MASK_STD_PERCENTAGE="${ISONET2_MASK_STD_PERCENTAGE:-50}"
ISONET2_MASK_Z_CROP="${ISONET2_MASK_Z_CROP:-0.2}"

ISONET2_FINAL_REFINE_CUBE_SIZE="${ISONET2_FINAL_REFINE_CUBE_SIZE:-128}"
ISONET2_FINAL_REFINE_EPOCHS="${ISONET2_FINAL_REFINE_EPOCHS:-100}"
ISONET2_FINAL_REFINE_MW_WEIGHT="${ISONET2_FINAL_REFINE_MW_WEIGHT:-200}"

###############################################################################
# Basic checks and summary
###############################################################################

[[ -x "$ISONET2_BIN" ]] || { echo "ERROR: missing/executable IsoNet2 binary: $ISONET2_BIN"; exit 1; }
[[ -d "$FULL_RECON_DIR" ]] || { echo "ERROR: missing full tomogram folder: $FULL_RECON_DIR"; exit 1; }
[[ -d "$EVN_RECON_DIR" ]] || { echo "ERROR: missing EVN tomogram folder: $EVN_RECON_DIR"; exit 1; }
[[ -d "$ODD_RECON_DIR" ]] || { echo "ERROR: missing ODD tomogram folder: $ODD_RECON_DIR"; exit 1; }
[[ -d "$ISONET2_WARP_CTF_DIR" ]] || { echo "ERROR: missing Warp CTF folder: $ISONET2_WARP_CTF_DIR"; exit 1; }

mkdir -p "$ISONET2_INPUT" "$ISONET2_OUTPUT"

cat <<SUMMARY
============================================================
IsoNet2 workflow
============================================================
Host: $(hostname)
Date: $(date)
PWD:  $(pwd)

Datasets:
$(printf '  %s\n' "${DATASETS[@]}")

Paths:
  BUILD:              $BUILD
  ISONET2_ENV:        $ISONET2_ENV
  ISONET2_BIN:        $ISONET2_BIN
  WARP_CTF_DIR:       $ISONET2_WARP_CTF_DIR
  ISONET2_INPUT:      $ISONET2_INPUT
  ISONET2_OUTPUT:     $ISONET2_OUTPUT
  ISONET2_STAR:       $ISONET2_STAR

Workflow:
  prepare_star:       $ISONET2_RUN_PREPARE_STAR
  initial_refine:     $ISONET2_RUN_INITIAL_REFINE
  initial_predict:    $ISONET2_RUN_INITIAL_PREDICT
  make_mask:          $ISONET2_RUN_MAKE_MASK
  final_refine:       $ISONET2_RUN_FINAL_REFINE
  final_predict:      $ISONET2_RUN_FINAL_PREDICT

Common training:
  method:             $ISONET2_METHOD
  gpuID:              $ISONET2_GPU_ID
  ncpus:              $ISONET2_NCPUS
  arch:               $ISONET2_ARCH
  batch_size:         $ISONET2_BATCH_SIZE
  CTF_mode:           $ISONET2_CTF_MODE
  bfactor:            $ISONET2_BFACTOR
  subtomos/tomogram:  $ISONET2_NUMBER_SUBTOMOS
  clean stage outputs: $ISONET2_CLEAN_STAGE_OUTPUTS
  CTF neighbor count:  $ISONET2_CTF_NEIGHBOR_COUNT
  CTF max deviation:   $ISONET2_CTF_MAX_DEVIATION_UM um AND $ISONET2_CTF_MAX_DEVIATION_FRACTION fractional

Initial Refine:
  cube_size:          $ISONET2_INITIAL_REFINE_CUBE_SIZE
  epochs:             $ISONET2_INITIAL_REFINE_EPOCHS
  mw_weight:          $ISONET2_INITIAL_REFINE_MW_WEIGHT

Mask:
  input_column:       $ISONET2_MASK_INPUT_COLUMN
  density_percentage:$ISONET2_MASK_DENSITY_PERCENTAGE
  std_percentage:    $ISONET2_MASK_STD_PERCENTAGE
  z_crop:             $ISONET2_MASK_Z_CROP

Final Refine:
  cube_size:          $ISONET2_FINAL_REFINE_CUBE_SIZE
  epochs:             $ISONET2_FINAL_REFINE_EPOCHS
  mw_weight:          $ISONET2_FINAL_REFINE_MW_WEIGHT
SUMMARY

###############################################################################
# Helpers
###############################################################################

run_cmd() {
    echo
    echo "Command:"
    printf '  %q ' "$@"
    echo
    echo
    "$@"
}

clean_stage_output() {
    local folder="$1"
    local label="$2"

    if [[ "$ISONET2_CLEAN_STAGE_OUTPUTS" -eq 1 ]]; then
        echo "Cleaning output for enabled stage $label: $folder"
        safe_rm_generated "$folder"
    else
        echo "ISONET2_CLEAN_STAGE_OUTPUTS=0; preserving $label output: $folder"
    fi
}

check_ddp_patch() {
    echo
    echo "============================================================"
    echo "Checking IsoNet2 DDP dynamic-port patch"
    echo "============================================================"

    "$ISONET2_ENV/bin/python" - <<'PY'
from pathlib import Path
import IsoNet.models.network as network

path = Path(network.__file__)
text = path.read_text()
count = text.count("DDP_DYNAMIC_PORT_PATCH")

print("network.py:", path)
print("DDP_DYNAMIC_PORT_PATCH count:", count)

if count != 2:
    raise SystemExit(
        "ERROR: expected DDP_DYNAMIC_PORT_PATCH count = 2. "
        "This environment is not patched for the multi-GPU DDP port issue."
    )
PY
}

link_selected_inputs() {
    echo
    echo "============================================================"
    echo "Linking only datasets selected in the pipeline controller"
    echo "============================================================"

    safe_rm_generated "$ISONET2_FULL_INPUT" "$ISONET2_EVN_INPUT" "$ISONET2_ODD_INPUT"
    mkdir -p "$ISONET2_FULL_INPUT" "$ISONET2_EVN_INPUT" "$ISONET2_ODD_INPUT"

    export FULL_RECON_DIR EVN_RECON_DIR ODD_RECON_DIR
    export ISONET2_FULL_INPUT ISONET2_EVN_INPUT ISONET2_ODD_INPUT

    "$ISONET2_ENV/bin/python" - "${DATASETS[@]}" <<'PY'
from pathlib import Path
import os
import sys

if len(sys.argv) < 2:
    raise SystemExit("ERROR: no datasets supplied to input linker")

datasets = sys.argv[1:]
full_dir = Path(os.environ["FULL_RECON_DIR"])
evn_dir = Path(os.environ["EVN_RECON_DIR"])
odd_dir = Path(os.environ["ODD_RECON_DIR"])
out_full = Path(os.environ["ISONET2_FULL_INPUT"])
out_evn = Path(os.environ["ISONET2_EVN_INPUT"])
out_odd = Path(os.environ["ISONET2_ODD_INPUT"])


def identify_dataset(stem: str) -> str | None:
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


def build_map(folder: Path, half_suffix: str | None):
    result = {dataset: [] for dataset in datasets}
    for path in sorted(folder.glob("*.mrc")):
        stem = path.stem
        if half_suffix is not None:
            if not stem.endswith(half_suffix):
                continue
            stem = stem[: -len(half_suffix)]
        dataset = identify_dataset(stem)
        if dataset is not None:
            result[dataset].append(path)
    return result


full_map = build_map(full_dir, None)
evn_map = build_map(evn_dir, "_EVN")
odd_map = build_map(odd_dir, "_ODD")


def choose(mapping, dataset: str, label: str) -> Path:
    candidates = mapping[dataset]
    if len(candidates) != 1:
        raise SystemExit(
            f"ERROR: expected exactly one {label} MRC for {dataset}; "
            f"found {len(candidates)}: {[str(x) for x in candidates]}"
        )
    return candidates[0]

seen_destinations = set()
for dataset in datasets:
    full = choose(full_map, dataset, "full")
    evn = choose(evn_map, dataset, "EVN")
    odd = choose(odd_map, dataset, "ODD")

    for source, destination_dir in (
        (full, out_full),
        (evn, out_evn),
        (odd, out_odd),
    ):
        destination = destination_dir / source.name
        if destination.name in seen_destinations:
            raise SystemExit(f"ERROR: duplicate linked filename: {destination.name}")
        destination.symlink_to(source.resolve())
        seen_destinations.add(destination.name)

    print(dataset)
    print("  full:", full)
    print("  EVN: ", evn)
    print("  ODD: ", odd)

print("OK: selected full/EVN/ODD inputs are uniquely matched.")
PY
}

detect_warp_metadata() {
    echo
    echo "============================================================"
    echo "Detecting per-dataset defocus and final tilt range from Warp"
    echo "============================================================"

    export ISONET2_WARP_CTF_DIR ISONET2_METADATA_JSON
    export ISONET2_CTF_NEIGHBOR_COUNT ISONET2_CTF_MAX_DEVIATION_UM
    export ISONET2_CTF_MAX_DEVIATION_FRACTION

    "$ISONET2_ENV/bin/python" - "${DATASETS[@]}" <<'PY'
from __future__ import annotations

from pathlib import Path
import json
import math
import os
import re
from statistics import median
import sys
import xml.etree.ElementTree as ET

if len(sys.argv) < 2:
    raise SystemExit("ERROR: no datasets supplied to Warp metadata detector")

datasets = sys.argv[1:]
ctf_dir = Path(os.environ["ISONET2_WARP_CTF_DIR"])
out_json = Path(os.environ["ISONET2_METADATA_JSON"])
neighbor_count = int(os.environ["ISONET2_CTF_NEIGHBOR_COUNT"])
max_deviation_um = float(os.environ["ISONET2_CTF_MAX_DEVIATION_UM"])
max_deviation_fraction = float(
    os.environ["ISONET2_CTF_MAX_DEVIATION_FRACTION"]
)

if neighbor_count < 1:
    raise SystemExit(
        f"ERROR: ISONET2_CTF_NEIGHBOR_COUNT must be >= 1, got {neighbor_count}"
    )
if not math.isfinite(max_deviation_um) or max_deviation_um < 0:
    raise SystemExit(
        f"ERROR: invalid ISONET2_CTF_MAX_DEVIATION_UM: {max_deviation_um}"
    )
if (
    not math.isfinite(max_deviation_fraction)
    or max_deviation_fraction < 0
):
    raise SystemExit(
        "ERROR: invalid ISONET2_CTF_MAX_DEVIATION_FRACTION: "
        f"{max_deviation_fraction}"
    )


def local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def find_element(root: ET.Element, name: str):
    for element in root.iter():
        if local_name(element.tag) == name:
            return element
    return None


def tokens(text: str):
    return [x for x in re.split(r"[\s,;]+", text.strip()) if x]


def parse_float_array(root: ET.Element, name: str):
    element = find_element(root, name)
    if element is None or not element.text:
        return []
    return [float(x) for x in tokens(element.text)]


def parse_bool_array(root: ET.Element, name: str):
    element = find_element(root, name)
    if element is None or not element.text:
        return []

    values = []
    for value in tokens(element.text):
        lowered = value.lower()
        if lowered in {"true", "1"}:
            values.append(True)
        elif lowered in {"false", "0"}:
            values.append(False)
        else:
            raise ValueError(f"invalid Boolean value in {name}: {value}")
    return values


def read_grid_by_z(root: ET.Element, grid_name: str):
    grid = find_element(root, grid_name)
    if grid is None:
        return {}

    values = {}
    duplicates = {}
    for node in grid.iter():
        if local_name(node.tag) != "Node" or "Value" not in node.attrib:
            continue
        try:
            z = int(round(float(node.attrib.get("Z", "0"))))
            value = float(node.attrib["Value"])
        except ValueError:
            continue
        if z in values:
            duplicates.setdefault(z, [values[z]]).append(value)
        values[z] = value

    if duplicates:
        raise ValueError(
            f"{grid_name} contains multiple nodes for the same Z index: {duplicates}"
        )
    return values


metadata = {}
for dataset in datasets:
    xml_path = ctf_dir / f"{dataset}.xml"
    if not xml_path.is_file():
        raise SystemExit(f"ERROR: missing Warp CTF XML for {dataset}: {xml_path}")

    try:
        root = ET.parse(xml_path).getroot()
        angles = parse_float_array(root, "Angles")
        use_tilt = parse_bool_array(root, "UseTilt")
        defocus_by_z = read_grid_by_z(root, "GridCTF")
    except Exception as exc:
        raise SystemExit(f"ERROR: failed to parse {xml_path}: {exc}") from exc

    if not angles:
        raise SystemExit(f"ERROR: no Angles array in {xml_path}")
    if not use_tilt:
        use_tilt = [True] * len(angles)
    if len(use_tilt) != len(angles):
        raise SystemExit(
            f"ERROR: Angles/UseTilt length mismatch for {dataset}: "
            f"{len(angles)} versus {len(use_tilt)}"
        )

    selected = [i for i, enabled in enumerate(use_tilt) if enabled]
    if not selected:
        raise SystemExit(f"ERROR: no enabled tilts for {dataset}")

    zero_index = min(selected, key=lambda i: abs(angles[i]))
    if zero_index not in defocus_by_z:
        raise SystemExit(
            f"ERROR: GridCTF has no value at selected zero-tilt index "
            f"{zero_index} for {dataset}"
        )

    defocus_um = abs(float(defocus_by_z[zero_index]))
    defocus_a = defocus_um * 10000.0
    tilt_min = min(angles[i] for i in selected)
    tilt_max = max(angles[i] for i in selected)

    neighbor_indices = sorted(
        (index for index in selected if index != zero_index),
        key=lambda index: abs(angles[index] - angles[zero_index]),
    )[:neighbor_count]
    if not neighbor_indices:
        raise SystemExit(
            f"ERROR: no neighboring enabled tilts are available for CTF sanity "
            f"checking in {dataset}"
        )

    neighbor_defocus = []
    for index in neighbor_indices:
        if index not in defocus_by_z:
            raise SystemExit(
                f"ERROR: GridCTF has no value at neighboring tilt index {index} "
                f"for {dataset}"
            )
        value = abs(float(defocus_by_z[index]))
        if not math.isfinite(value) or value <= 0:
            raise SystemExit(
                f"ERROR: invalid neighboring Warp defocus for {dataset} at "
                f"angle {angles[index]:.6f}: {value}"
            )
        neighbor_defocus.append(value)

    local_median_um = float(median(neighbor_defocus))
    absolute_deviation_um = abs(defocus_um - local_median_um)
    relative_deviation = absolute_deviation_um / local_median_um

    if (
        absolute_deviation_um > max_deviation_um
        and relative_deviation > max_deviation_fraction
    ):
        neighbor_text = ", ".join(
            f"{angles[index]:.3f}deg={value:.6f}um"
            for index, value in zip(neighbor_indices, neighbor_defocus)
        )
        raise SystemExit(
            f"ERROR: zero-neighborhood Warp CTF sanity check failed for {dataset}. "
            f"Closest-to-zero defocus={defocus_um:.6f} um at "
            f"{angles[zero_index]:.6f} deg; nearby median={local_median_um:.6f} um; "
            f"absolute deviation={absolute_deviation_um:.6f} um; relative "
            f"deviation={relative_deviation:.3f}. Limits are "
            f">{max_deviation_um:.6f} um AND >{max_deviation_fraction:.3f}. "
            f"Nearby fits: {neighbor_text}"
        )

    numeric_values = [
        defocus_um,
        defocus_a,
        tilt_min,
        tilt_max,
        angles[zero_index],
        local_median_um,
        absolute_deviation_um,
        relative_deviation,
    ]
    if not all(math.isfinite(x) for x in numeric_values):
        raise SystemExit(f"ERROR: non-finite Warp metadata for {dataset}")
    if defocus_um <= 0:
        raise SystemExit(f"ERROR: non-positive Warp defocus for {dataset}: {defocus_um}")
    if tilt_min >= tilt_max:
        raise SystemExit(
            f"ERROR: invalid selected tilt range for {dataset}: {tilt_min} to {tilt_max}"
        )

    metadata[dataset] = {
        "warp_ctf_xml": str(xml_path.resolve()),
        "selected_tilt_count": len(selected),
        "disabled_tilt_count": len(angles) - len(selected),
        "zero_tilt_index_0based": zero_index,
        "zero_tilt_angle_deg": angles[zero_index],
        "defocus_um": defocus_um,
        "defocus_A": defocus_a,
        "ctf_neighbor_indices_0based": neighbor_indices,
        "ctf_neighbor_angles_deg": [angles[index] for index in neighbor_indices],
        "ctf_neighbor_defocus_um": neighbor_defocus,
        "ctf_neighbor_median_um": local_median_um,
        "ctf_absolute_deviation_um": absolute_deviation_um,
        "ctf_relative_deviation": relative_deviation,
        "tilt_min_deg": tilt_min,
        "tilt_max_deg": tilt_max,
    }

    print(dataset)
    print(f"  Warp CTF XML:       {xml_path}")
    print(f"  selected tilts:     {len(selected)}")
    print(f"  disabled tilts:     {len(angles) - len(selected)}")
    print(f"  closest-to-zero:    {angles[zero_index]:.6f} deg")
    print(f"  fitted defocus:     {defocus_um:.6f} um")
    print(f"  nearby CTF median:  {local_median_um:.6f} um")
    print(
        f"  CTF deviation:      {absolute_deviation_um:.6f} um "
        f"({relative_deviation:.3f} fractional)"
    )
    print(f"  IsoNet2 defocus:    {defocus_a:.1f} A")
    print(f"  final tilt range:   {tilt_min:.6f} to {tilt_max:.6f} deg")

out_json.parent.mkdir(parents=True, exist_ok=True)
out_json.write_text(json.dumps(metadata, indent=2) + "\n")
print(f"Wrote metadata: {out_json}")
PY
}

patch_star_metadata() {
    echo
    echo "============================================================"
    echo "Writing detected metadata into STAR rows"
    echo "============================================================"

    export ISONET2_STAR ISONET2_METADATA_JSON ISONET2_NUMBER_SUBTOMOS

    "$ISONET2_ENV/bin/python" - "${DATASETS[@]}" <<'PY'
from pathlib import Path
import json
import os
import pandas as pd
import starfile
import sys

if len(sys.argv) < 2:
    raise SystemExit("ERROR: no datasets supplied to STAR metadata patcher")

datasets = sys.argv[1:]
star_path = Path(os.environ["ISONET2_STAR"])
metadata = json.loads(Path(os.environ["ISONET2_METADATA_JSON"]).read_text())
number_subtomos = float(os.environ["ISONET2_NUMBER_SUBTOMOS"])

obj = starfile.read(star_path)
if isinstance(obj, dict):
    if len(obj) != 1:
        raise SystemExit(f"ERROR: expected one STAR table, found {list(obj)}")
    key = next(iter(obj))
    df = obj[key]
else:
    key = None
    df = obj


def identify_dataset(path_value) -> str:
    if pd.isna(path_value):
        raise ValueError("missing rlnTomoName")
    stem = Path(str(path_value)).stem
    matches = [d for d in datasets if stem == d or stem.startswith(d + "_")]
    if not matches:
        raise ValueError(
            f"cannot map tomogram '{stem}' to pipeline datasets {datasets}"
        )
    longest = max(len(dataset) for dataset in matches)
    winners = [dataset for dataset in matches if len(dataset) == longest]
    if len(winners) != 1:
        raise ValueError(
            f"cannot uniquely map tomogram '{stem}' to pipeline datasets {datasets}; "
            f"matches={winners}"
        )
    return winners[0]

used = []
for index, row in df.iterrows():
    dataset = identify_dataset(row["rlnTomoName"])
    values = metadata.get(dataset)
    if values is None:
        raise SystemExit(f"ERROR: no detected metadata for {dataset}")

    df.at[index, "rlnDefocus"] = float(values["defocus_A"])
    df.at[index, "rlnTiltMin"] = float(values["tilt_min_deg"])
    df.at[index, "rlnTiltMax"] = float(values["tilt_max_deg"])
    df.at[index, "rlnNumberSubtomo"] = number_subtomos
    used.append(dataset)

if sorted(used) != sorted(datasets):
    raise SystemExit(
        f"ERROR: STAR rows do not match pipeline datasets. rows={used}, expected={datasets}"
    )

if key is None:
    starfile.write(df, star_path, overwrite=True)
else:
    obj[key] = df
    starfile.write(obj, star_path, overwrite=True)

columns = [
    "rlnIndex",
    "rlnTomoName",
    "rlnDefocus",
    "rlnTiltMin",
    "rlnTiltMax",
    "rlnNumberSubtomo",
]
print(df[columns].to_string(index=False))
PY
}

preview_star() {
    echo
    echo "STAR preview:"
    sed -n '1,100p' "$ISONET2_STAR" || true
}

check_star_paths() {
    local column="$1"
    local label="$2"

    echo
    echo "============================================================"
    echo "Checking STAR column: $column ($label)"
    echo "============================================================"

    export ISONET2_STAR CHECK_STAR_COLUMN="$column"

    "$ISONET2_ENV/bin/python" - <<'PY'
from pathlib import Path
import os
import pandas as pd
import starfile
import sys

star = Path(os.environ["ISONET2_STAR"])
column = os.environ["CHECK_STAR_COLUMN"]
obj = starfile.read(star)
df = next(iter(obj.values())) if isinstance(obj, dict) else obj

if column not in df.columns:
    sys.exit(f"ERROR: STAR lacks column {column}")

bad = []
for _, row in df.iterrows():
    idx = row.get("rlnIndex", "?")
    value = row[column]
    if pd.isna(value) or str(value) in {"", "None", "<NA>", "nan"}:
        bad.append((idx, str(value), "empty_or_NA"))
    elif not Path(str(value)).exists():
        bad.append((idx, str(value), "file_missing"))

if bad:
    print(f"ERROR: bad entries in {column}:")
    for item in bad:
        print("  row_index=%s value=%s reason=%s" % item)
    sys.exit(1)

print(f"OK: every row has an existing file in {column}")
PY
}

check_star_metadata() {
    echo
    echo "============================================================"
    echo "Checking per-row CTF and tilt metadata"
    echo "============================================================"

    export ISONET2_STAR ISONET2_NUMBER_SUBTOMOS

    "$ISONET2_ENV/bin/python" - <<'PY'
from pathlib import Path
import math
import os
import starfile
import sys

star = Path(os.environ["ISONET2_STAR"])
expected_subtomos = float(os.environ["ISONET2_NUMBER_SUBTOMOS"])
obj = starfile.read(star)
df = next(iter(obj.values())) if isinstance(obj, dict) else obj

required = [
    "rlnDefocus",
    "rlnTiltMin",
    "rlnTiltMax",
    "rlnNumberSubtomo",
]
for column in required:
    if column not in df.columns:
        sys.exit(f"ERROR: STAR lacks {column}")

for _, row in df.iterrows():
    values = {column: float(row[column]) for column in required}
    if not all(math.isfinite(x) for x in values.values()):
        sys.exit(f"ERROR: non-finite STAR metadata: {values}")
    if values["rlnDefocus"] <= 0:
        sys.exit(f"ERROR: invalid rlnDefocus: {values['rlnDefocus']}")
    if values["rlnTiltMin"] >= values["rlnTiltMax"]:
        sys.exit(
            f"ERROR: invalid tilt range: {values['rlnTiltMin']} to "
            f"{values['rlnTiltMax']}"
        )
    if values["rlnNumberSubtomo"] != expected_subtomos:
        sys.exit(
            f"ERROR: rlnNumberSubtomo={values['rlnNumberSubtomo']} "
            f"but expected {expected_subtomos}"
        )

print(df[[
    "rlnIndex",
    "rlnTomoName",
    "rlnDefocus",
    "rlnTiltMin",
    "rlnTiltMax",
    "rlnNumberSubtomo",
]].to_string(index=False))
print("OK: metadata are finite and valid for every STAR row.")
PY
}

check_pt_tree() {
    local folder="$1"
    local label="$2"

    echo
    echo "QC model NaN/Inf check: $label"
    echo "  target: $folder"

    [[ -d "$folder" ]] || { echo "ERROR: missing folder: $folder"; exit 1; }
    export QC_PT_FOLDER="$folder"

    "$ISONET2_ENV/bin/python" - <<'PY'
from pathlib import Path
import os
import sys
import torch

folder = Path(os.environ["QC_PT_FOLDER"])
checkpoints = sorted(folder.glob("*.pt"))
if not checkpoints:
    sys.exit(f"ERROR: no .pt files found in {folder}")

for path in checkpoints:
    print("  " + str(path))
    try:
        try:
            state = torch.load(path, map_location="cpu", weights_only=False)
        except TypeError:
            state = torch.load(path, map_location="cpu")
    except Exception as exc:
        sys.exit(f"ERROR: failed to load {path}: {exc}")

    if isinstance(state, dict) and "model_state_dict" in state:
        state = state["model_state_dict"]

    counts = {"total": 0, "bad": 0}

    def visit(value):
        if torch.is_tensor(value) and (
            value.is_floating_point() or value.is_complex()
        ):
            counts["total"] += value.numel()
            counts["bad"] += int((~torch.isfinite(value)).sum().item())
        elif isinstance(value, dict):
            for child in value.values():
                visit(child)
        elif isinstance(value, (list, tuple)):
            for child in value:
                visit(child)

    visit(state)
    print(f"    floating/complex params: {counts['total']}")
    print(f"    NaN/Inf params:          {counts['bad']}")

    if counts["bad"]:
        sys.exit(f"ERROR: NaN/Inf parameters found in {path}")

print("OK: all model checkpoints are finite.")
PY
}

check_mrc_tree() {
    local folder="$1"
    local label="$2"

    echo
    echo "QC MRC finite/black check: $label"
    echo "  target: $folder"

    [[ -d "$folder" ]] || { echo "ERROR: missing folder: $folder"; exit 1; }
    export QC_MRC_FOLDER="$folder"

    "$ISONET2_ENV/bin/python" - <<'PY'
from pathlib import Path
import os
import sys
import mrcfile
import numpy as np

folder = Path(os.environ["QC_MRC_FOLDER"])
mrcs = sorted(folder.glob("*.mrc"))
if not mrcs:
    sys.exit(f"ERROR: no .mrc files found in {folder}")

for path in mrcs:
    with mrcfile.mmap(path, permissive=True, mode="r") as mrc:
        array = mrc.data
        z_step = max(1, array.shape[0] // 64)
        y_step = max(1, array.shape[1] // 512)
        x_step = max(1, array.shape[2] // 512)
        sample = np.asarray(
            array[::z_step, ::y_step, ::x_step], dtype=np.float32
        )

    finite = np.isfinite(sample)
    finite_fraction = float(finite.mean())
    if finite.any():
        values = sample[finite]
        minimum = float(values.min())
        maximum = float(values.max())
        average = float(values.mean())
        std = float(values.std())
    else:
        minimum = maximum = average = std = float("nan")

    print("  " + str(path))
    print(
        f"    shape={sample.shape} finite={finite_fraction:.6f} "
        f"min={minimum:.6g} max={maximum:.6g} "
        f"mean={average:.6g} std={std:.6g}"
    )

    if finite_fraction < 1.0:
        sys.exit(f"ERROR: non-finite values found in {path}")
    if not np.isfinite(std) or std == 0:
        sys.exit(f"ERROR: zero/invalid standard deviation in {path}")

print("OK: all sampled MRC outputs are finite and non-flat.")
PY
}

find_model() {
    local folder="$1"
    local cube_size="$2"
    local epochs="$3"

    local final_model="$folder/network_${ISONET2_METHOD}_${ISONET2_ARCH}_${cube_size}_full.pt"
    local epoch_model="$folder/network_${ISONET2_METHOD}_${ISONET2_ARCH}_${cube_size}_epoch${epochs}_full.pt"

    if [[ -f "$final_model" ]]; then
        echo "$final_model"
    elif [[ -f "$epoch_model" ]]; then
        echo "$epoch_model"
    else
        echo "ERROR: expected final model was not found." >&2
        echo "Checked:" >&2
        echo "  $final_model" >&2
        echo "  $epoch_model" >&2
        find "$folder" -maxdepth 1 -type f -name "*.pt" -print | sort >&2 || true
        exit 1
    fi
}

run_refine() {
    local output_dir="$1"
    local cube_size="$2"
    local epochs="$3"
    local mw_weight="$4"

    local command=(
        "$ISONET2_BIN" refine "$ISONET2_STAR"
        --output_dir "$output_dir"
        --method "$ISONET2_METHOD"
        --arch "$ISONET2_ARCH"
        --cube_size "$cube_size"
        --epochs "$epochs"
        --mw_weight "$mw_weight"
        --CTF_mode "$ISONET2_CTF_MODE"
        --bfactor "$ISONET2_BFACTOR"
        --gpuID "$ISONET2_GPU_ID"
        --ncpus "$ISONET2_NCPUS"
    )

    if [[ "$ISONET2_BATCH_SIZE" != "auto" && "$ISONET2_BATCH_SIZE" != "None" ]]; then
        command+=(--batch_size "$ISONET2_BATCH_SIZE")
    fi

    run_cmd "${command[@]}"
}

###############################################################################
# Environment
###############################################################################

# This conda environment's MKL activation hook is not safe under nounset.
set +u
if [[ -n "${CONDA_SH:-}" ]]; then
    source "$CONDA_SH"
else
    command -v conda >/dev/null 2>&1 || { echo "ERROR: conda not found; set CLUSTER_INIT or CONDA_SH" >&2; exit 1; }
    source "$(conda info --base)/etc/profile.d/conda.sh"
fi
conda activate "$ISONET2_ENV"
set -u

echo
echo "Activated conda env:"
echo "  $(which python)"
echo "  $(python --version)"
echo "  $(which isonet.py || true)"

check_ddp_patch
link_selected_inputs
detect_warp_metadata

###############################################################################
# prepare_star and per-row metadata assignment
###############################################################################

if [[ "$ISONET2_RUN_PREPARE_STAR" -eq 1 ]]; then
    echo
    echo "============================================================"
    echo "Running IsoNet2 prepare_star"
    echo "============================================================"

    rm -f "$ISONET2_STAR"

    # prepare_star accepts only one global tilt_min/tilt_max. Temporary values
    # are used here and immediately replaced per STAR row from Warp metadata.
    run_cmd "$ISONET2_BIN" prepare_star \
        --full "$ISONET2_FULL_INPUT" \
        --even "$ISONET2_EVN_INPUT" \
        --odd "$ISONET2_ODD_INPUT" \
        --star_name "$ISONET2_STAR" \
        --pixel_size "$ISONET2_PIXEL_SIZE" \
        --defocus 10000 \
        --cs "$ISONET2_CS" \
        --voltage "$ISONET2_VOLTAGE" \
        --ac "$ISONET2_AC" \
        --tilt_min -60 \
        --tilt_max 60 \
        --number_subtomos "$ISONET2_NUMBER_SUBTOMOS"

    patch_star_metadata
    preview_star
else
    echo "ISONET2_RUN_PREPARE_STAR=0, skipping prepare_star."
    [[ -f "$ISONET2_STAR" ]] || {
        echo "ERROR: prepare_star skipped but STAR is missing: $ISONET2_STAR"
        exit 1
    }
fi

check_star_paths "rlnTomoName" "full tomograms"
check_star_paths "rlnTomoReconstructedTomogramHalf1" "EVN half tomograms"
check_star_paths "rlnTomoReconstructedTomogramHalf2" "ODD half tomograms"
check_star_metadata

###############################################################################
# Initial Refine
###############################################################################

if [[ "$ISONET2_RUN_INITIAL_REFINE" -eq 1 ]]; then
    echo
    echo "============================================================"
    echo "Running initial Refine"
    echo "============================================================"

    clean_stage_output "$INITIAL_REFINE_DIR" "initial_refine"

    run_refine \
        "$INITIAL_REFINE_DIR" \
        "$ISONET2_INITIAL_REFINE_CUBE_SIZE" \
        "$ISONET2_INITIAL_REFINE_EPOCHS" \
        "$ISONET2_INITIAL_REFINE_MW_WEIGHT"

    check_pt_tree "$INITIAL_REFINE_DIR" "initial_refine"
    check_mrc_tree "$INITIAL_REFINE_DIR" "initial_refine_preview"
else
    echo "ISONET2_RUN_INITIAL_REFINE=0, skipping initial Refine."
fi

###############################################################################
# Initial Predict for all tomograms
###############################################################################

if [[ "$ISONET2_RUN_INITIAL_PREDICT" -eq 1 ]]; then
    echo
    echo "============================================================"
    echo "Running initial Predict for all STAR rows"
    echo "============================================================"

    INITIAL_MODEL="$(find_model \
        "$INITIAL_REFINE_DIR" \
        "$ISONET2_INITIAL_REFINE_CUBE_SIZE" \
        "$ISONET2_INITIAL_REFINE_EPOCHS")"

    echo "Using initial model:"
    echo "  $INITIAL_MODEL"

    clean_stage_output "$INITIAL_PREDICT_DIR" "initial_predict"

    run_cmd "$ISONET2_BIN" predict "$ISONET2_STAR" "$INITIAL_MODEL" \
        --output_dir "$INITIAL_PREDICT_DIR" \
        --gpuID "$ISONET2_GPU_ID" \
        --output_prefix "initial"

    check_star_paths "rlnCorrectedTomoName" "initial corrected tomograms"
    check_mrc_tree "$INITIAL_PREDICT_DIR" "initial_predict"
else
    echo "ISONET2_RUN_INITIAL_PREDICT=0, skipping initial Predict."
fi

###############################################################################
# Mask generation from initial corrected tomograms
###############################################################################

if [[ "$ISONET2_RUN_MAKE_MASK" -eq 1 ]]; then
    echo
    echo "============================================================"
    echo "Running mask generation"
    echo "============================================================"

    check_star_paths "$ISONET2_MASK_INPUT_COLUMN" "mask input"
    clean_stage_output "$MASK_DIR" "make_mask"

    run_cmd "$ISONET2_BIN" make_mask "$ISONET2_STAR" \
        --output_dir "$MASK_DIR" \
        --input_column "$ISONET2_MASK_INPUT_COLUMN" \
        --density_percentage "$ISONET2_MASK_DENSITY_PERCENTAGE" \
        --std_percentage "$ISONET2_MASK_STD_PERCENTAGE" \
        --z_crop "$ISONET2_MASK_Z_CROP"

    check_star_paths "rlnMaskName" "masks"
    check_mrc_tree "$MASK_DIR" "mask"
else
    echo "ISONET2_RUN_MAKE_MASK=0, skipping make_mask."
fi

###############################################################################
# Final Refine
###############################################################################

if [[ "$ISONET2_RUN_FINAL_REFINE" -eq 1 ]]; then
    echo
    echo "============================================================"
    echo "Running final Refine"
    echo "============================================================"

    check_star_paths "rlnMaskName" "final Refine masks"
    clean_stage_output "$FINAL_REFINE_DIR" "final_refine"

    run_refine \
        "$FINAL_REFINE_DIR" \
        "$ISONET2_FINAL_REFINE_CUBE_SIZE" \
        "$ISONET2_FINAL_REFINE_EPOCHS" \
        "$ISONET2_FINAL_REFINE_MW_WEIGHT"

    check_pt_tree "$FINAL_REFINE_DIR" "final_refine"
    check_mrc_tree "$FINAL_REFINE_DIR" "final_refine_preview"
else
    echo "ISONET2_RUN_FINAL_REFINE=0, skipping final Refine."
fi

###############################################################################
# Final Predict for all tomograms
###############################################################################

if [[ "$ISONET2_RUN_FINAL_PREDICT" -eq 1 ]]; then
    echo
    echo "============================================================"
    echo "Running final Predict for all STAR rows"
    echo "============================================================"

    FINAL_MODEL="$(find_model \
        "$FINAL_REFINE_DIR" \
        "$ISONET2_FINAL_REFINE_CUBE_SIZE" \
        "$ISONET2_FINAL_REFINE_EPOCHS")"

    echo "Using final model:"
    echo "  $FINAL_MODEL"

    clean_stage_output "$FINAL_PREDICT_DIR" "final_predict"

    run_cmd "$ISONET2_BIN" predict "$ISONET2_STAR" "$FINAL_MODEL" \
        --output_dir "$FINAL_PREDICT_DIR" \
        --gpuID "$ISONET2_GPU_ID" \
        --output_prefix "final"

    check_star_paths "rlnCorrectedTomoName" "final corrected tomograms"
    check_mrc_tree "$FINAL_PREDICT_DIR" "final_predict"
else
    echo "ISONET2_RUN_FINAL_PREDICT=0, skipping final Predict."
fi

###############################################################################
# Final summary
###############################################################################

echo
echo "============================================================"
echo "IsoNet2 workflow finished"
echo "============================================================"
echo "STAR:             $ISONET2_STAR"
echo "Detected metadata:$ISONET2_METADATA_JSON"
echo "Initial Refine:   $INITIAL_REFINE_DIR"
echo "Initial Predict:  $INITIAL_PREDICT_DIR"
echo "Mask:             $MASK_DIR"
echo "Final Refine:     $FINAL_REFINE_DIR"
echo "Final Predict:    $FINAL_PREDICT_DIR"

echo
echo "Final STAR columns:"
export ISONET2_STAR
"$ISONET2_ENV/bin/python" - <<'PY'
from pathlib import Path
import os
import starfile

star = Path(os.environ["ISONET2_STAR"])
obj = starfile.read(star)
df = next(iter(obj.values())) if isinstance(obj, dict) else obj

columns = [column for column in [
    "rlnIndex",
    "rlnTomoName",
    "rlnTomoReconstructedTomogramHalf1",
    "rlnTomoReconstructedTomogramHalf2",
    "rlnDefocus",
    "rlnTiltMin",
    "rlnTiltMax",
    "rlnNumberSubtomo",
    "rlnMaskName",
    "rlnCorrectedTomoName",
] if column in df.columns]

print(df[columns].to_string(index=False))
PY

echo
echo "Done."
