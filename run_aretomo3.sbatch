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

###############################################################################
# Activate CUDA
###############################################################################

if [[ -n "${ARETOMO_CUDA_MODULE:-}" ]]; then
    command -v module >/dev/null 2>&1 || { echo "ERROR: module command unavailable" >&2; exit 1; }
    if [[ "${ARETOMO_MODULE_PURGE:-0}" -eq 1 ]]; then module purge; fi
    module load "$ARETOMO_CUDA_MODULE"
fi

###############################################################################
# Required variables from pipeline controller
###############################################################################

: "${BUILD:?ERROR: BUILD is not set}"
: "${BASE:?ERROR: BASE is not set}"
: "${DATA_ROOT:?ERROR: DATA_ROOT is not set}"
: "${ARETOMO3:?ERROR: ARETOMO3 is not set}"
: "${ARETOMO_OUT:?ERROR: ARETOMO_OUT is not set}"
: "${ARETOMO_TEMP:?ERROR: ARETOMO_TEMP is not set}"
: "${LOG_DIR:?ERROR: LOG_DIR is not set}"
: "${GAIN_FILE:?ERROR: GAIN_FILE is not set}"

MDOC_MERGER="${SCRIPTS_DIR:?SCRIPTS_DIR missing}/make_aretomo3_mdoc.py"

###############################################################################
# Read dataset folders passed from pipeline controller
###############################################################################

if [[ "$#" -eq 0 ]]; then
    echo "ERROR: no dataset folders were passed to run_aretomo3.sbatch"
    exit 1
fi

DATASETS=("$@")

###############################################################################
# Print job information
###############################################################################

echo "============================================================"
echo "AreTomo3 batch job"
echo "============================================================"
echo "Date:       $(date)"
echo "Host:       $(hostname)"
echo "Job name:   ${SLURM_JOB_NAME:-unknown}"
echo "Job ID:     ${SLURM_JOB_ID:-unknown}"
echo "BUILD:      $BUILD"
echo "BASE:       $BASE"
echo "DATA_ROOT:  $DATA_ROOT"
echo "AreTomo3:   $ARETOMO3"
echo "Mdoc merge: $MDOC_MERGER"
echo

echo "Datasets in this Slurm job:"
printf '  %s\n' "${DATASETS[@]}"
echo

echo "GPU information:"
nvidia-smi
echo

echo "Loaded modules:"
if command -v module >/dev/null 2>&1; then module list; else echo "No module command"; fi
echo

[[ -x "$ARETOMO3" ]] || {
    echo "ERROR: AreTomo3 executable not found or not executable:"
    echo "$ARETOMO3"
    exit 1
}

[[ -f "$MDOC_MERGER" ]] || {
    echo "ERROR: mdoc merger script not found:"
    echo "$MDOC_MERGER"
    exit 1
}

[[ -f "$GAIN_FILE" ]] || {
    echo "ERROR: gain file not found:"
    echo "$GAIN_FILE"
    exit 1
}

###############################################################################
# Print AreTomo3 parameters
###############################################################################

echo "AreTomo3 parameters:"
echo "  PIX_SIZE:              ${PIX_SIZE:?missing}"
echo "  KV:                    ${KV:?missing}"
echo "  CS:                    ${CS:?missing}"
echo "  DOSE_PER_TILT:         ${DOSE_PER_TILT:?missing}"
echo "  EER_FRAMES_PER_TILT:   ${EER_FRAMES_PER_TILT:?missing}"
echo "  FM_INT:                ${FM_INT:?missing}"
echo "  FM_DOSE:               ${FM_DOSE:?missing}"
echo "  EER_SAMPLING:          ${EER_SAMPLING:?missing}"
echo "  MC_BIN:                ${MC_BIN:?missing}"
echo "  MCPATCH:               ${MCPATCH_X:?missing} ${MCPATCH_Y:?missing}"
echo "  GROUP:                 ${GROUP_GLOBAL:?missing} ${GROUP_LOCAL:?missing}"
echo "  TILT_AXIS:             ${TILT_AXIS:?missing}"
echo "  TILT_AXIS_REFINE:      ${TILT_AXIS_REFINE:?missing}"
echo "  ATBIN:                 ${ATBIN:?missing}"
echo "  ATPATCH:               ${ATPATCH_X:?missing} ${ATPATCH_Y:?missing}"
echo "  VOLZ:                  ${VOLZ:?missing}"
echo "  WBP:                   ${WBP:?missing}"
echo "  FLIP_VOL:              ${FLIP_VOL:?missing}"
echo "  TILT_COR:              ${TILT_COR:?missing}"
echo "  OUT_IMOD:              ${OUT_IMOD:?missing}"
echo "  SPLIT_SUM:             ${SPLIT_SUM:?missing}"
echo "  DARK_TOL:              ${DARK_TOL:?missing}"
echo "  CORR_CTF:              ${CORR_CTF:?missing}"
echo "  AMP_CONTRAST:          ${AMP_CONTRAST:?missing}"
echo "  GAIN_FILE:             ${GAIN_FILE:?missing}"
echo

###############################################################################
# Run AreTomo3 on each dataset folder, one by one
###############################################################################

for DATASET in "${DATASETS[@]}"; do
    echo
    echo "============================================================"
    echo "Starting dataset: $DATASET"
    echo "============================================================"
    echo "Start time: $(date)"

    RAW_DIR="$DATA_ROOT/$DATASET"
    OUT_DIR="$ARETOMO_OUT/$DATASET"
    TMP_DIR="$ARETOMO_TEMP/$DATASET"
    DATASET_LOG_DIR="$LOG_DIR/$DATASET"

    MERGED_MDOC="$RAW_DIR/$DATASET.mdoc"
    MDOC_PREFIX="$RAW_DIR/$DATASET"

    mkdir -p "$OUT_DIR" "$TMP_DIR" "$DATASET_LOG_DIR"

    [[ -d "$RAW_DIR" ]] || {
        echo "ERROR: raw dataset folder does not exist:"
        echo "$RAW_DIR"
        exit 1
    }

    EER_COUNT=$(find -H "$RAW_DIR" -maxdepth 1 -type f -name "*.eer" | wc -l | tr -d ' ')
    PER_TILT_MDOC_COUNT=$(find -H "$RAW_DIR" -maxdepth 1 -type f -name "*.eer.mdoc" | wc -l | tr -d ' ')

    echo "Raw dir:          $RAW_DIR"
    echo "Out dir:          $OUT_DIR"
    echo "Temp dir:         $TMP_DIR"
    echo "Log dir:          $DATASET_LOG_DIR"
    echo "Merged mdoc:      $MERGED_MDOC"
    echo
    echo "Number of .eer files:          $EER_COUNT"
    echo "Number of per-tilt .eer.mdoc:  $PER_TILT_MDOC_COUNT"
    echo

    [[ "$EER_COUNT" -gt 0 ]] || {
        echo "ERROR: no .eer files found in:"
        echo "$RAW_DIR"
        exit 1
    }

    [[ "$PER_TILT_MDOC_COUNT" -gt 0 ]] || {
        echo "ERROR: no per-tilt .eer.mdoc files found in:"
        echo "$RAW_DIR"
        exit 1
    }

    echo "Checking exact EER/.eer.mdoc basename pairing..."
    python3 - "$RAW_DIR" <<'PY_PAIR'
from pathlib import Path
import sys

folder = Path(sys.argv[1])
eer_names = {path.name for path in folder.glob("*.eer")}
sidecar_names = {path.name[:-5] for path in folder.glob("*.eer.mdoc")}

missing_sidecars = sorted(eer_names - sidecar_names)
missing_eers = sorted(sidecar_names - eer_names)

print(f"  complete EER/sidecar pairs: {len(eer_names & sidecar_names)}")
print(f"  EER files without sidecars: {len(missing_sidecars)}")
print(f"  sidecars without EER files: {len(missing_eers)}")

if missing_sidecars:
    print("EER files missing matching .eer.mdoc sidecars:")
    for name in missing_sidecars:
        print("  " + name)

if missing_eers:
    print("Sidecars missing matching EER files:")
    for name in missing_eers:
        print("  " + name + ".mdoc")

if missing_sidecars or missing_eers:
    raise SystemExit(1)
PY_PAIR
    echo

    echo "First few per-tilt .eer.mdoc files:"
    find -H "$RAW_DIR" -maxdepth 1 -type f -name "*.eer.mdoc" | sort | awk 'NR<=10 {print}'
    echo

    echo "Generating merged AreTomo3 tilt-series mdoc in raw dataset folder..."
    python3 "$MDOC_MERGER" \
      --dataset-dir "$RAW_DIR" \
      --dataset-name "$DATASET" \
      --dose-per-tilt "$DOSE_PER_TILT"
    echo

    [[ -f "$MERGED_MDOC" ]] || {
        echo "ERROR: merged mdoc was not generated:"
        echo "$MERGED_MDOC"
        exit 1
    }

    Z_COUNT=$(grep -c '^\[ZValue' "$MERGED_MDOC" || true)
    FRAMESET_COUNT=$(grep -c '^\[FrameSet' "$MERGED_MDOC" || true)
    SUBFRAME_COUNT=$(grep -c '^SubFramePath' "$MERGED_MDOC" || true)
    EXPOSURE_COUNT=$(grep -c '^ExposureDose' "$MERGED_MDOC" || true)

    echo "Merged mdoc check:"
    echo "  File:                $MERGED_MDOC"
    echo "  ZValue sections:     $Z_COUNT"
    echo "  FrameSet sections:   $FRAMESET_COUNT"
    echo "  SubFramePath lines:  $SUBFRAME_COUNT"
    echo "  ExposureDose lines:  $EXPOSURE_COUNT"
    echo

    [[ "$Z_COUNT" -eq "$PER_TILT_MDOC_COUNT" ]] || {
        echo "ERROR: merged mdoc ZValue count does not match per-tilt mdoc count."
        exit 1
    }

    [[ "$FRAMESET_COUNT" -eq 0 ]] || {
        echo "ERROR: merged mdoc still contains FrameSet sections."
        exit 1
    }

    [[ "$SUBFRAME_COUNT" -eq "$PER_TILT_MDOC_COUNT" ]] || {
        echo "ERROR: merged mdoc SubFramePath count does not match per-tilt mdoc count."
        exit 1
    }

    echo "Checking every SubFramePath entry points to an existing EER file..."
    python3 - "$MERGED_MDOC" <<'PY_CHECK'
import sys
from pathlib import Path

mdoc = Path(sys.argv[1])
folder = mdoc.parent

bad_space = []
missing = []

for line in mdoc.read_text(errors="replace").splitlines():
    if line.startswith("SubFramePath"):
        if "=" not in line:
            bad_space.append(line)
            continue

        value = line.split("=", 1)[1]

        if value != value.strip():
            bad_space.append(line)

        eer_name = value.strip()
        eer_path = folder / eer_name

        if not eer_path.is_file():
            missing.append(str(eer_path))

print(f"  SubFramePath entries with leading/trailing whitespace: {len(bad_space)}")
print(f"  Missing EER files: {len(missing)}")

if bad_space:
    print("First bad SubFramePath entries:")
    for x in bad_space[:10]:
        print("  " + repr(x))

if missing:
    print("First missing EER files:")
    for x in missing[:10]:
        print("  " + x)

if bad_space or missing:
    sys.exit(1)
PY_CHECK
    echo

    ATPATCH_ARGS=()
    if (( ATPATCH_X > 0 && ATPATCH_Y > 0 )); then
        ATPATCH_ARGS=(-AtPatch "$ATPATCH_X" "$ATPATCH_Y")
    fi

    ARETOMO3_CMD=(
      "$ARETOMO3"
      -Cmd 0
      -InPrefix "$MDOC_PREFIX"
      -InSuffix .mdoc
      -OutDir "$OUT_DIR/"
      -Gain "$GAIN_FILE"
      -FlipGain "$FLIP_GAIN"
      -Gpu "${ARETOMO_GPU_ID:-0}"
      -PixSize "$PIX_SIZE"
      -Kv "$KV"
      -Cs "$CS"
      -AmpContrast "$AMP_CONTRAST"
      -EerSampling "$EER_SAMPLING"
      -McBin "$MC_BIN"
      -McPatch "$MCPATCH_X" "$MCPATCH_Y"
      -FmInt "$FM_INT"
      -FmDose "$FM_DOSE"
      -Group "$GROUP_GLOBAL" "$GROUP_LOCAL"
      -SplitSum "$SPLIT_SUM"
      -VolZ "$VOLZ"
      -TiltAxis "$TILT_AXIS" "$TILT_AXIS_REFINE"
      "${ATPATCH_ARGS[@]}"
      -AtBin "$ATBIN"
      -OutXF 1
      -OutImod "$OUT_IMOD"
      -Wbp "$WBP"
      -FlipVol "$FLIP_VOL"
      -TiltCor "$TILT_COR"
      -DarkTol "$DARK_TOL"
      -CorrCTF "$CORR_CTF"
      -Serial 1
      -TmpDir "$TMP_DIR/"
      -LogDir "$DATASET_LOG_DIR/"
    )

    echo "Running AreTomo3 command:"
    printf ' %q' "${ARETOMO3_CMD[@]}"
    echo
    echo

    "${ARETOMO3_CMD[@]}"

    echo
    echo "Finished dataset: $DATASET"
    echo "Finish time: $(date)"
    echo

    echo "Output files for $DATASET:"
    find "$OUT_DIR" -maxdepth 2 -type f | sort | awk 'NR<=100 {print}'
    echo

    echo "AreTomo3 log files for $DATASET:"
    find "$DATASET_LOG_DIR" -maxdepth 2 -type f | sort | awk 'NR<=100 {print}'
    echo
done

echo
echo "============================================================"
echo "AreTomo3 finished for all datasets"
echo "End time: $(date)"
echo "============================================================"
