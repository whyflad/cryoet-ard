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
    echo "ERROR: no dataset folders were passed to run_missalignment.sbatch"
    exit 1
fi

DATASETS=("$@")

echo "============================================================"
echo "MissAlignment / WarpTools batch job"
echo "============================================================"
echo "Date:        $(date)"
echo "Host:        $(hostname)"
echo "Job name:    ${SLURM_JOB_NAME:-unknown}"
echo "Job ID:      ${SLURM_JOB_ID:-unknown}"
echo
echo "BUILD:                ${BUILD:?missing}"
echo "BASE:                 ${BASE:?missing}"
echo "DATA_ROOT:            ${DATA_ROOT:?missing}"
echo "ARETOMO_OUT:          ${ARETOMO_OUT:?missing}"
echo "MISSALIGN_INPUT:      ${MISSALIGN_INPUT:?missing}"
echo "MISSALIGN_OUTPUT:     ${MISSALIGN_OUTPUT:?missing}"
echo "WARP_PROJECT:         ${WARP_PROJECT:?missing}"
echo "WARPTOOLS_ENV:        ${WARPTOOLS_ENV:?missing}"
echo "MISSALIGN_ENV:        ${MISSALIGN_ENV:?missing}"
echo

echo "Datasets:"
printf '  %s\n' "${DATASETS[@]}"
echo

echo "GPU information:"
nvidia-smi
echo

echo "Parameters:"
echo "  PIX_SIZE:                       ${PIX_SIZE:?missing}"
echo "  KV:                             ${KV:?missing}"
echo "  DOSE_PER_TILT:                  ${DOSE_PER_TILT:?missing}"
echo "  TOMO_DIMENSIONS:                ${TOMO_DIMENSIONS:?missing}"
echo "  VOLZ:                           ${VOLZ:?missing}"
echo "  MISS_PREPARE_STACKS:            ${MISS_PREPARE_STACKS:?missing}"
echo "  MISS_TRAINING_DEVICES:          ${MISS_TRAINING_DEVICES:?missing}"
echo "  MISS_RECONSTRUCTION_DEVICES:    ${MISS_RECONSTRUCTION_DEVICES:?missing}"
echo "  MISS_DATALOADERS_PER_TRAINER:   ${MISS_DATALOADERS_PER_TRAINER:?missing}"
echo "  MISS_START_AT_ITERATION:        ${MISS_START_AT_ITERATION:?missing}"
echo "  MISS_BATCH_SIZE:                ${MISS_BATCH_SIZE:?missing}"
echo "  REBUILD_WARP_PROJECT:           ${REBUILD_WARP_PROJECT:?missing}"
echo

if [[ -n "${CONDA_SH:-}" ]]; then
    source "$CONDA_SH"
else
    command -v conda >/dev/null 2>&1 || { echo "ERROR: conda not found; set CLUSTER_INIT or CONDA_SH" >&2; exit 1; }
    source "$(conda info --base)/etc/profile.d/conda.sh"
fi

safe_conda_activate() {
    set +u
    conda activate "$1"
    set -u
}

safe_conda_deactivate() {
    set +u
    conda deactivate || true
    set -u
}

if [[ "$REBUILD_WARP_PROJECT" -eq 1 ]]; then
    echo "REBUILD_WARP_PROJECT=1, removing old Warp project:"
    echo "$WARP_PROJECT"
    safe_rm_generated "$WARP_PROJECT"
fi

# input_missalignment is a generated link tree. Rebuild it from the current
# DATASETS list so stale dataset directories cannot leak into later stages.
echo "Rebuilding generated MissAlignment input tree: $MISSALIGN_INPUT"
safe_rm_generated "$MISSALIGN_INPUT"
mkdir -p "$MISSALIGN_INPUT" "$MISSALIGN_OUTPUT"
mkdir -p "$WARP_PROJECT"/{movies,mdoc,alignments,warp_frameseries,warp_tiltseries,tomostar,logs,tmp}

###############################################################################
# Prepare input_missalignment links from AreTomo3 output
###############################################################################

echo
echo "============================================================"
echo "Preparing MissAlignment input links from AreTomo3 output"
echo "============================================================"

for DATASET in "${DATASETS[@]}"; do
    SRC="$ARETOMO_OUT/$DATASET"
    DST="$MISSALIGN_INPUT/$DATASET"

    echo
    echo "Dataset: $DATASET"
    echo "  AreTomo3 output:      $SRC"
    echo "  MissAlignment input:  $DST"

    mkdir -p "$DST"

    required=(
      "$SRC/$DATASET.mrc"
      "$SRC/${DATASET}_ODD.mrc"
      "$SRC/${DATASET}_EVN.mrc"
      "$SRC/${DATASET}.aln"
      "$SRC/${DATASET}_TLT.txt"
      "$SRC/${DATASET}_Imod/${DATASET}_st.xf"
      "$SRC/${DATASET}_Imod/${DATASET}_st.tlt"
      "$SRC/${DATASET}_Imod/${DATASET}_st.xtilt"
    )

    for f in "${required[@]}"; do
        if [[ ! -f "$f" ]]; then
            echo "ERROR: missing required AreTomo3 file:"
            echo "$f"
            exit 1
        fi
    done

    ln -sfn "$SRC/$DATASET.mrc"                         "$DST/tilt_series.mrc"
    ln -sfn "$SRC/${DATASET}_ODD.mrc"                   "$DST/odd.mrc"
    ln -sfn "$SRC/${DATASET}_EVN.mrc"                   "$DST/even.mrc"
    ln -sfn "$SRC/${DATASET}.aln"                       "$DST/aretomo.aln"
    ln -sfn "$SRC/${DATASET}_TLT.txt"                   "$DST/tilt_angles.txt"
    ln -sfn "$SRC/${DATASET}_Imod/${DATASET}_st.xf"     "$DST/imod.xf"
    ln -sfn "$SRC/${DATASET}_Imod/${DATASET}_st.tlt"    "$DST/imod.tlt"
    ln -sfn "$SRC/${DATASET}_Imod/${DATASET}_st.xtilt"  "$DST/imod.xtilt"

    {
        echo "Dataset: $DATASET"
        echo "AreTomo3 output: $SRC"
        echo
        echo "tilt_series.mrc -> $SRC/$DATASET.mrc"
        echo "odd.mrc         -> $SRC/${DATASET}_ODD.mrc"
        echo "even.mrc        -> $SRC/${DATASET}_EVN.mrc"
        echo "aretomo.aln     -> $SRC/${DATASET}.aln"
        echo "tilt_angles.txt -> $SRC/${DATASET}_TLT.txt"
        echo "imod.xf         -> $SRC/${DATASET}_Imod/${DATASET}_st.xf"
        echo "imod.tlt        -> $SRC/${DATASET}_Imod/${DATASET}_st.tlt"
        echo "imod.xtilt      -> $SRC/${DATASET}_Imod/${DATASET}_st.xtilt"
    } > "$DST/input_manifest.txt"

    ls -lh "$DST"
done

###############################################################################
# Activate WarpTools environment
###############################################################################

echo
echo "============================================================"
echo "Activating WarpTools environment"
echo "============================================================"

safe_conda_activate "$WARPTOOLS_ENV"

which WarpTools
WarpTools --help | head -n 5
echo

python - <<'PY_CHECK'
try:
    import mrcfile
    print("mrcfile import: OK")
except Exception as e:
    raise SystemExit(f"ERROR: mrcfile is missing in the WarpTools env. Original error: {e}")
PY_CHECK

###############################################################################
# Prepare WarpTools input from input_missalignment
###############################################################################

echo
echo "============================================================"
echo "Preparing WarpTools input from input_missalignment"
echo "============================================================"

python - "$WARP_PROJECT" "$MISSALIGN_INPUT" "$PIX_SIZE" "$DOSE_PER_TILT" \
  "$KV" "$TOMO_DIMENSIONS" "$VOLZ" "${DATASETS[@]}" <<'PY_PREP'
import sys
from pathlib import Path

import mrcfile
import numpy as np

project = Path(sys.argv[1])
miss_input = Path(sys.argv[2])
pix_size = float(sys.argv[3])
dose_per_tilt = float(sys.argv[4])
voltage_kv = float(sys.argv[5])
tomo_dimensions = sys.argv[6]
configured_volz = int(sys.argv[7])
datasets = sys.argv[8:]

try:
    configured_x, configured_y, configured_z = [
        int(value) for value in tomo_dimensions.lower().split("x")
    ]
except Exception as exc:
    raise SystemExit(
        f"ERROR: TOMO_DIMENSIONS must have the form XxYxZ, got {tomo_dimensions!r}"
    ) from exc

if configured_z != configured_volz:
    raise SystemExit(
        f"ERROR: TOMO_DIMENSIONS Z ({configured_z}) does not match VOLZ "
        f"({configured_volz})"
    )

movies_dir = project / "movies"
mdoc_dir = project / "mdoc"
alignments_dir = project / "alignments"
average_dir = project / "warp_frameseries" / "average"

movies_dir.mkdir(parents=True, exist_ok=True)
mdoc_dir.mkdir(parents=True, exist_ok=True)
alignments_dir.mkdir(parents=True, exist_ok=True)
average_dir.mkdir(parents=True, exist_ok=True)


def read_tlt(path: Path):
    tilts = []
    for line in path.read_text(errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        tilts.append(float(line.split()[0]))
    return tilts


for dataset in datasets:
    print()
    print(f"===== Preparing {dataset} =====")

    at_in = miss_input / dataset
    stack_path = at_in / "tilt_series.mrc"
    even_stack_path = at_in / "even.mrc"
    odd_stack_path = at_in / "odd.mrc"
    tlt_path = at_in / "tilt_angles.txt"
    xf_src = at_in / "imod.xf"
    tlt_src = at_in / "imod.tlt"
    xtilt_src = at_in / "imod.xtilt"

    for p in [
        stack_path,
        even_stack_path,
        odd_stack_path,
        tlt_path,
        xf_src,
        tlt_src,
        xtilt_src,
    ]:
        if not p.is_file():
            raise SystemExit(f"ERROR: required input missing: {p}")

    tilts = read_tlt(tlt_path)

    with mrcfile.open(stack_path, permissive=True) as m:
        stack = np.asarray(m.data)

        if stack.ndim != 3:
            raise SystemExit(f"ERROR: expected 3D tilt stack, got shape {stack.shape}: {stack_path}")

        ntilts, ny, nx = stack.shape

        if ntilts != len(tilts):
            raise SystemExit(
                f"ERROR: stack Z ({ntilts}) != tilt angle count ({len(tilts)}) for {dataset}"
            )
        if (nx, ny) != (configured_x, configured_y):
            raise SystemExit(
                f"ERROR: {dataset} full stack dimensions are {nx}x{ny}, but "
                f"TOMO_DIMENSIONS specifies {configured_x}x{configured_y}"
            )

        print(f"Stack: {stack_path}")
        print(f"  shape: {stack.shape}")

        for label, half_path in (("EVN", even_stack_path), ("ODD", odd_stack_path)):
            with mrcfile.open(half_path, permissive=True) as half_mrc:
                half_shape = tuple(int(value) for value in half_mrc.data.shape)
            if half_shape != (ntilts, ny, nx):
                raise SystemExit(
                    f"ERROR: {dataset} {label} stack shape {half_shape} does not "
                    f"match full stack shape {(ntilts, ny, nx)}"
                )
            print(f"  {label} shape: {half_shape}")

        print(
            f"  validated TOMO_DIMENSIONS={configured_x}x{configured_y}x{configured_z} "
            f"and VOLZ={configured_volz}"
        )

        mdoc_lines = []
        mdoc_lines.append(f"T = Synthetic mdoc for WarpTools from AreTomo3 tilt stack {dataset}")
        mdoc_lines.append(f"Voltage = {voltage_kv:g}")
        mdoc_lines.append("")

        for i in range(ntilts):
            tilt_index = i + 1
            movie_name = f"{dataset}_tilt_{tilt_index:03d}.mrc"
            movie_path = movies_dir / movie_name

            with mrcfile.new(movie_path, overwrite=True) as out:
                out.set_data(stack[i].astype(np.float32, copy=False))
                out.voxel_size = pix_size

            avg_path = average_dir / movie_name
            if avg_path.exists() or avg_path.is_symlink():
                avg_path.unlink()
            avg_path.symlink_to(movie_path)

            mdoc_lines.append(f"[ZValue = {i}]")
            mdoc_lines.append(f"TiltAngle = {tilts[i]:.6f}")
            mdoc_lines.append(f"ExposureDose = {dose_per_tilt:.6f}")
            mdoc_lines.append(f"PixelSpacing = {pix_size:.6f}")
            mdoc_lines.append(f"SubFramePath = {movie_name}")
            mdoc_lines.append("DateTime = 01-Jan-2000  00:00:00")
            mdoc_lines.append(f"TimeStamp = {946684800 + i}")
            mdoc_lines.append("")

    mdoc_out = mdoc_dir / f"{dataset}.mdoc"
    mdoc_out.write_text("\n".join(mdoc_lines).rstrip() + "\n")

    this_align_dir = alignments_dir / dataset
    this_align_dir.mkdir(parents=True, exist_ok=True)

    for target in [
        this_align_dir / f"{dataset}.xf",
        this_align_dir / f"{dataset}.tlt",
        this_align_dir / f"{dataset}.xtilt",
    ]:
        if target.exists() or target.is_symlink():
            target.unlink()

    (this_align_dir / f"{dataset}.xf").symlink_to(xf_src)
    (this_align_dir / f"{dataset}.tlt").symlink_to(tlt_src)
    (this_align_dir / f"{dataset}.xtilt").symlink_to(xtilt_src)

    print(f"Wrote mdoc: {mdoc_out}")
    print(f"Linked alignments: {this_align_dir}")
    print(f"Number of tilts: {ntilts}")

print()
print("WarpTools input preparation finished.")
PY_PREP

echo
echo "Prepared project tree:"
find "$WARP_PROJECT" -maxdepth 3 \( -type f -o -type l \) | sort | awk 'NR<=200 {print}'
echo

###############################################################################
# WarpTools frame-series settings and CTF
###############################################################################

echo
echo "============================================================"
echo "Creating WarpTools frame-series settings"
echo "============================================================"

WarpTools create_settings \
  --folder_data "$WARP_PROJECT/movies" \
  --folder_processing "$WARP_PROJECT/warp_frameseries" \
  --output "$WARP_PROJECT/warp_frameseries.settings" \
  --extension "*.mrc" \
  --angpix "$PIX_SIZE" \
  --exposure "$DOSE_PER_TILT"

echo
echo "Running WarpTools fs_ctf..."
WarpTools fs_ctf \
  --settings "$WARP_PROJECT/warp_frameseries.settings" \
  --range_max 7 \
  --defocus_max 8 \
  --perdevice 1

###############################################################################
# WarpTools tilt-series project
###############################################################################

echo
echo "============================================================"
echo "Importing tilt-series metadata into WarpTools"
echo "============================================================"

safe_rm_generated "$WARP_PROJECT/tomostar"
mkdir -p "$WARP_PROJECT/tomostar"

WarpTools ts_import \
  --mdocs "$WARP_PROJECT/mdoc" \
  --frameseries "$WARP_PROJECT/warp_frameseries" \
  --tilt_exposure "$DOSE_PER_TILT" \
  --min_intensity 0 \
  --dont_invert \
  --output "$WARP_PROJECT/tomostar"

echo
echo "Creating WarpTools tilt-series settings..."
WarpTools create_settings \
  --output "$WARP_PROJECT/warp_tiltseries.settings" \
  --folder_processing "$WARP_PROJECT/warp_tiltseries" \
  --folder_data "$WARP_PROJECT/tomostar" \
  --extension "*.tomostar" \
  --angpix "$PIX_SIZE" \
  --exposure "$DOSE_PER_TILT" \
  --tomo_dimensions "$TOMO_DIMENSIONS"

echo
echo "Generating WarpTools tilt stacks at ${MISS_PREPARE_STACKS} A/px..."
WarpTools ts_stack \
  --settings "$WARP_PROJECT/warp_tiltseries.settings" \
  --angpix "$MISS_PREPARE_STACKS" \
  --perdevice 1

echo
echo "Importing AreTomo3/IMOD alignments into WarpTools..."
WarpTools ts_import_alignments \
  --settings "$WARP_PROJECT/warp_tiltseries.settings" \
  --alignments "$WARP_PROJECT/alignments" \
  --alignment_angpix "$PIX_SIZE"

echo
echo "WarpTools preparation finished."

###############################################################################
# Switch to MissAlignment environment
###############################################################################

echo
echo "============================================================"
echo "Switching to MissAlignment environment"
echo "============================================================"

safe_conda_deactivate
safe_conda_activate "$MISSALIGN_ENV"

which python
python -V
which miss-alignment
miss-alignment --help | head -n 20
echo

###############################################################################
# Update Warp XML attributes for MissAlignment
###############################################################################

echo
echo "============================================================"
echo "Updating Warp XML attributes for MissAlignment"
echo "============================================================"

cd "$WARP_PROJECT/warp_tiltseries"

python - "$PIX_SIZE" "$TOMO_DIMENSIONS" <<'PY_XML'
import sys
from pathlib import Path

import torch
from warpylib import TiltSeries

pix = float(sys.argv[1])
tomo_dims = sys.argv[2]
x, y, z = [int(v) for v in tomo_dims.lower().split("x")]

xml_files = sorted(Path(".").glob("*.xml"))
if not xml_files:
    raise SystemExit("ERROR: no Warp tilt-series XML files found in warp_tiltseries")

for xml in xml_files:
    ts = TiltSeries(xml)

    ts.image_dimensions_physical = torch.tensor(
        [x * pix, y * pix],
        dtype=torch.float32,
    )

    ts.volume_dimensions_physical = torch.tensor(
        [x * pix, y * pix, z * pix],
        dtype=torch.float32,
    )

    ts.save_meta(xml)
    print(f"Updated XML: {xml}")

print(f"Updated {len(xml_files)} XML files.")
PY_XML

###############################################################################
# Write MissAlignment config
###############################################################################

CONFIG="$WARP_PROJECT/warp_tiltseries/config.yaml"

cat > "$CONFIG" <<EOF_CONFIG
general:
  training_directory: "$WARP_PROJECT/warp_tiltseries"
  apply_ctf: False
  iteration_settings:
    - { downsample: 3, alignment: anchoring }
    - { downsample: 2, alignment: anchoring }
    - { downsample: 1, alignment: global }
    - { downsample: 1, alignment: global }
    - { downsample: 1, alignment: [3, 3] }
    - { downsample: 1, alignment: [3, 3] }
    - { downsample: 1, alignment: [3, 3] }
    - { downsample: 1, alignment: [3, 3] }
  seed: 45132

model_training:
  model_architecture: 'default'
  model_checkpoint: null
  loss_margin: 0.5
  learning_rate: 1.0e-3
  weight_decay: 1.0e-4
  max_epochs_per_iteration: 30
  warmup_steps: 500
  multistep_lr_scheduler:
    milestones: [5, 15]
    gamma: 0.5

data_loading:
  batch_size: $MISS_BATCH_SIZE
  patch_size: 96
  steps_per_epoch: 1000

shift_generation:
  trajectory_probability: 0.5
  trajectory_max_shift: 10.0
  jitter_probability: 0.5
  jitter_max_std: 2.0
  outlier_probability: 0.5
  outlier_max_shift: 20.0
  fracture_probability: 0.5
  fracture_max_shift: 20.0

tilt_series_alignment:
  patch_size: 96
  patch_overlap: 0.1
  batch_size: $MISS_BATCH_SIZE
EOF_CONFIG

echo "Wrote MissAlignment config:"
echo "$CONFIG"
echo

###############################################################################
# Run MissAlignment
###############################################################################

echo
echo "============================================================"
echo "Running MissAlignment"
echo "============================================================"

export OMP_NUM_THREADS=1
export MKL_NUM_THREADS=1

LONG_TMPDIR="$MISSALIGN_OUTPUT/tmp"
mkdir -p "$LONG_TMPDIR"

SHORT_TMPDIR="${SCRATCH_SYMLINK_PARENT:-/tmp}/${USER}_missalign_${SLURM_JOB_ID:-$$}"
if [[ -e "$SHORT_TMPDIR" || -L "$SHORT_TMPDIR" ]]; then
    echo "ERROR: scratch link already exists; inspect manually: $SHORT_TMPDIR" >&2
    exit 1
fi
ln -s "$LONG_TMPDIR" "$SHORT_TMPDIR"

export TMPDIR="$SHORT_TMPDIR"
export TMP="$SHORT_TMPDIR"
export TEMP="$SHORT_TMPDIR"

echo "TMPDIR: $TMPDIR -> $LONG_TMPDIR"

miss-alignment train \
  --config-file "$CONFIG" \
  --training-devices "$MISS_TRAINING_DEVICES" \
  --reconstruction-devices "$MISS_RECONSTRUCTION_DEVICES" \
  --dataloaders-per-trainer "$MISS_DATALOADERS_PER_TRAINER" \
  --start-at-iteration "$MISS_START_AT_ITERATION" \
  --prepare-stacks "$MISS_PREPARE_STACKS"

echo
echo "============================================================"
echo "MissAlignment finished"
echo "End time: $(date)"
echo "============================================================"
