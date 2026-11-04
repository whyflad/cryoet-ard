#!/usr/bin/env bash
# Portable Slurm controller. Run with `bash pipeline.sh --dry-run` or `bash pipeline.sh`.
# Job submissions happen from the submission/login node using `sbatch --wait`.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${PIPELINE_CONFIG:-$SCRIPTS_DIR/config.sh}"
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
      --dry-run) DRY_RUN=1 ;;
      --config=*) CONFIG_FILE="${arg#--config=}" ;;
      --help|-h)
        echo "Usage: bash pipeline.sh [--config=/absolute/path/config.sh] [--dry-run]"
        exit 0 ;;
      *) echo "ERROR: unknown argument $arg" >&2; exit 2 ;;
    esac
done

[[ -f "$CONFIG_FILE" ]] || {
    echo "ERROR: missing private configuration file: $CONFIG_FILE" >&2
    echo "Copy config.example.sh to a private location outside Git, then use --config=/path/to/config.sh." >&2
    exit 1
}
# User-supplied Bash config (trusted local file, not arbitrary downloaded content).
# shellcheck disable=SC1090
source "$CONFIG_FILE"

require() { local var="$1"; [[ -n "${!var:-}" ]] || { echo "ERROR: configure $var in $CONFIG_FILE" >&2; exit 1; }; }
for key in RUN_DIR DATA_ROOT GAIN_FILE ARETOMO3 WARPTOOLS_ENV MISSALIGN_ENV ISONET2_ENV \
  PIX_SIZE KV CS DOSE_PER_TILT EER_FRAMES_PER_TILT TILT_AXIS VOLZ TOMO_DIMENSIONS WARP_RECON_ANGPIX; do
    require "$key"
done
if [[ "$(declare -p DATASETS 2>/dev/null || :)" != declare\ -a* ]] || [[ ${#DATASETS[@]} -eq 0 ]]; then
    echo "ERROR: DATASETS must be a nonempty Bash array in $CONFIG_FILE" >&2; exit 1
fi
for dataset in "${DATASETS[@]}"; do
    [[ "$dataset" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && [[ "$dataset" != *..* ]] || {
        echo "ERROR: dataset name must be a simple directory basename: $dataset" >&2; exit 1;
    }
done

if [[ "$DRY_RUN" -eq 1 ]]; then
    BUILD="$(realpath -m "$RUN_DIR")"
else
    mkdir -p "$RUN_DIR"
    BUILD="$(cd "$RUN_DIR" && pwd -P)"
fi
DATA_ROOT="$(cd "$DATA_ROOT" && pwd -P)" || exit 1
BASE="$(dirname "$BUILD")"
if [[ "$BUILD" == "$SCRIPTS_DIR" || "$BUILD" == "$SCRIPTS_DIR/"* || \
      "$BUILD" == "$DATA_ROOT" || "$BUILD" == "$DATA_ROOT/"* || \
      "$DATA_ROOT" == "$BUILD/"* || "$BUILD" == / || "$BUILD" == "$BASE" ]]; then
    echo "ERROR: RUN_DIR must be a distinct, dedicated processing directory" >&2; exit 1
fi
RUN_TAG="$(basename "$BUILD")"
CLUSTER_INIT="${CLUSTER_INIT:-}"
SCRATCH_SYMLINK_PARENT="${SCRATCH_SYMLINK_PARENT:-/tmp}"
ISONET2_BIN="${ISONET2_BIN:-$ISONET2_ENV/bin/isonet.py}"
MISSALIGN_ROOT="$(dirname "$MISSALIGN_ENV")"
WARPTOOLS_ROOT="$(dirname "$WARPTOOLS_ENV")"
ISONET2_ROOT="$(dirname "$ISONET2_ENV")"

# sbatch command-line options override any stage-script #SBATCH defaults.
declare -p SLURM_COMMON_ARGS >/dev/null 2>&1 || SLURM_COMMON_ARGS=()
declare -p SLURM_ARETOMO_ARGS >/dev/null 2>&1 || SLURM_ARETOMO_ARGS=()
declare -p SLURM_MISSALIGN_ARGS >/dev/null 2>&1 || SLURM_MISSALIGN_ARGS=()
declare -p SLURM_WARP_ARGS >/dev/null 2>&1 || SLURM_WARP_ARGS=()
declare -p SLURM_ISONET2_ARGS >/dev/null 2>&1 || SLURM_ISONET2_ARGS=()

# Derived paths are always relative to RUN_DIR, never to the public code repository.
ARETOMO_OUT="$BUILD/out"
ARETOMO_TEMP="$BUILD/temp"
MISSALIGN_INPUT="$BUILD/input_missalignment"
MISSALIGN_OUTPUT="$BUILD/output_missalignment"
WARP_PROJECT="$MISSALIGN_OUTPUT/warp_project"
WARP_RECON_INPUT="$BUILD/input_warp_reconstruction"
WARP_RECON_OUTPUT="$BUILD/output_warp_reconstruction"
WARP_RECON_MISSALIGN_PROJECT="$WARP_RECON_INPUT/missalignment_warp_project"
WARP_RECON_SETTINGS="$WARP_RECON_INPUT/warp_tiltseries.settings"
WARP_RECON_INPUT_PROCESSING="$WARP_RECON_INPUT/warp_tiltseries"
WARP_RECON_TOMOSTAR="$WARP_RECON_INPUT/tomostar"
WARP_RECON_CTF_OUTPUT="$WARP_RECON_OUTPUT/ctf"
WARP_RECON_TOMO_OUTPUT="$WARP_RECON_OUTPUT/tomograms"
ISONET2_INPUT="$BUILD/input_isonet2"
ISONET2_OUTPUT="$BUILD/output_isonet2"
ISONET2_FULL_INPUT="$ISONET2_INPUT/full"
ISONET2_STAR="$ISONET2_OUTPUT/tomograms.star"
ISONET2_WARP_CTF_DIR="$WARP_RECON_CTF_OUTPUT"
LOG_DIR="$BUILD/log"
FM_DOSE="$(awk -v d="$DOSE_PER_TILT" -v n="$EER_FRAMES_PER_TILT" 'BEGIN {if(n<=0) exit 1; printf "%.8f", d/n}')"
ISONET2_PIXEL_SIZE="$WARP_RECON_ANGPIX"
ISONET2_CS="$CS"
ISONET2_VOLTAGE="$KV"
ISONET2_AC="$AMP_CONTRAST"

# Guard generated paths: these must all remain inside the dedicated run directory.
for generated in "$ARETOMO_OUT" "$ARETOMO_TEMP" "$MISSALIGN_INPUT" "$MISSALIGN_OUTPUT" \
                 "$WARP_PROJECT" "$WARP_RECON_INPUT" "$WARP_RECON_OUTPUT" \
                 "$ISONET2_INPUT" "$ISONET2_OUTPUT" "$LOG_DIR"; do
    [[ "$generated" == "$BUILD/"* ]] || { echo "ERROR: unsafe generated path: $generated" >&2; exit 1; }
done

###############################################################################
# 8. Export variables for sbatch scripts
###############################################################################

export BASE BUILD DATA_ROOT LOG_DIR RUN_TAG SCRIPTS_DIR CLUSTER_INIT SCRATCH_SYMLINK_PARENT
export CONDA_SH ARETOMO_CUDA_MODULE ARETOMO_MODULE_PURGE ARETOMO_GPU_ID

export ARETOMO3 ARETOMO_OUT ARETOMO_TEMP
export PIX_SIZE KV CS DOSE_PER_TILT EER_FRAMES_PER_TILT FM_INT FM_DOSE
export EER_SAMPLING MC_BIN MCPATCH_X MCPATCH_Y GROUP_GLOBAL GROUP_LOCAL
export TILT_AXIS TILT_AXIS_REFINE ATBIN VOLZ WBP FLIP_GAIN FLIP_VOL TILT_COR
export OUT_IMOD SPLIT_SUM DARK_TOL ATPATCH_X ATPATCH_Y CORR_CTF AMP_CONTRAST GAIN_FILE

export MISSALIGN_ROOT MISSALIGN_ENV MISSALIGN_INPUT MISSALIGN_OUTPUT WARP_PROJECT
export TOMO_DIMENSIONS MISS_PREPARE_STACKS MISS_TRAINING_DEVICES MISS_RECONSTRUCTION_DEVICES
export MISS_DATALOADERS_PER_TRAINER MISS_START_AT_ITERATION MISS_BATCH_SIZE REBUILD_WARP_PROJECT

export WARPTOOLS_ROOT WARPTOOLS_ENV
export WARP_RECON_INPUT WARP_RECON_OUTPUT WARP_RECON_MISSALIGN_PROJECT
export WARP_RECON_SETTINGS WARP_RECON_INPUT_PROCESSING WARP_RECON_TOMOSTAR
export WARP_RECON_CTF_OUTPUT WARP_RECON_TOMO_OUTPUT
export WARP_RECON_ANGPIX WARP_RECON_RUN_CTF WARP_CTF_RANGE_HIGH WARP_CTF_DEFOCUS_MAX
export WARP_RECON_PERDEVICE WARP_RECON_HALF_MAPS WARP_RECON_FORCE_FLOAT32 WARP_RECON_DONT_INVERT

export ISONET2_ROOT ISONET2_ENV ISONET2_BIN
export ISONET2_INPUT ISONET2_OUTPUT ISONET2_FULL_INPUT ISONET2_STAR ISONET2_INPUT_MODE
export ISONET2_WARP_CTF_DIR ISONET2_PIXEL_SIZE ISONET2_CS ISONET2_VOLTAGE ISONET2_AC
export ISONET2_NUMBER_SUBTOMOS ISONET2_CLEAN_STAGE_OUTPUTS
export ISONET2_CTF_NEIGHBOR_COUNT ISONET2_CTF_MAX_DEVIATION_UM
export ISONET2_CTF_MAX_DEVIATION_FRACTION
export ISONET2_RUN_PREPARE_STAR ISONET2_RUN_INITIAL_REFINE ISONET2_RUN_INITIAL_PREDICT
export ISONET2_RUN_MAKE_MASK ISONET2_RUN_FINAL_REFINE ISONET2_RUN_FINAL_PREDICT
export ISONET2_GPU_ID ISONET2_NCPUS ISONET2_ARCH ISONET2_BATCH_SIZE
export ISONET2_METHOD ISONET2_CTF_MODE ISONET2_BFACTOR
export ISONET2_INITIAL_REFINE_CUBE_SIZE ISONET2_INITIAL_REFINE_EPOCHS
export ISONET2_INITIAL_REFINE_MW_WEIGHT
export ISONET2_MASK_INPUT_COLUMN ISONET2_MASK_DENSITY_PERCENTAGE
export ISONET2_MASK_STD_PERCENTAGE ISONET2_MASK_Z_CROP
export ISONET2_FINAL_REFINE_CUBE_SIZE ISONET2_FINAL_REFINE_EPOCHS
export ISONET2_FINAL_REFINE_MW_WEIGHT

###############################################################################
# 9. Shared setup
###############################################################################

if [[ "$DRY_RUN" -ne 1 ]]; then
    mkdir -p "$LOG_DIR" "$ARETOMO_OUT" "$ARETOMO_TEMP"
    mkdir -p "$MISSALIGN_INPUT" "$MISSALIGN_OUTPUT"
    mkdir -p "$WARP_RECON_INPUT" "$WARP_RECON_OUTPUT"
    mkdir -p "$ISONET2_INPUT" "$ISONET2_OUTPUT"
fi

print_summary() {
    echo "============================================================"
    echo "Pipeline controller"
    echo "============================================================"
    echo "BUILD/run folder:      $BUILD"
    echo "BASE/software root:    $BASE"
    echo "DATA_ROOT:             $DATA_ROOT"
    echo
    echo "Run-specific folders:"
    echo "  LOG_DIR:             $LOG_DIR"
    echo "  ARETOMO_OUT:         $ARETOMO_OUT"
    echo "  ARETOMO_TEMP:        $ARETOMO_TEMP"
    echo "  MISSALIGN_INPUT:     $MISSALIGN_INPUT"
    echo "  MISSALIGN_OUTPUT:    $MISSALIGN_OUTPUT"
    echo "  WARP_PROJECT:        $WARP_PROJECT"
    echo "  WARP_RECON_INPUT:    $WARP_RECON_INPUT"
    echo "  WARP_RECON_OUTPUT:   $WARP_RECON_OUTPUT"
    echo "  ISONET2_INPUT:       $ISONET2_INPUT"
    echo "  ISONET2_OUTPUT:      $ISONET2_OUTPUT"
    echo
    echo "Merged mdoc location:"
    echo "  $DATA_ROOT/\$DATASET/\$DATASET.mdoc"
    echo
    echo "Datasets:"
    printf '  %s\n' "${DATASETS[@]}"
    echo
}

submit_and_wait() {
    local stage_name="$1"
    shift

    echo
    echo "============================================================"
    echo "Submitting $stage_name and waiting for it to finish"
    echo "============================================================"

    "$@"

    echo
    echo "============================================================"
    echo "$stage_name finished successfully"
    echo "============================================================"
}

run_aretomo3_stage() {
    if [[ "$RUN_ARETOMO3" -ne 1 ]]; then
        echo "RUN_ARETOMO3=0, skipping AreTomo3."
        return
    fi

    [[ -x "$ARETOMO3" ]] || { echo "ERROR: missing AreTomo3: $ARETOMO3"; exit 1; }
    [[ -f "$GAIN_FILE" ]] || { echo "ERROR: missing gain file: $GAIN_FILE"; exit 1; }
    [[ -f "$SCRIPTS_DIR/run_aretomo3.sbatch" ]] || { echo "ERROR: missing $SCRIPTS_DIR/run_aretomo3.sbatch"; exit 1; }

    for d in "${DATASETS[@]}"; do
        [[ -d "$DATA_ROOT/$d" ]] || { echo "ERROR: missing raw dataset folder: $DATA_ROOT/$d"; exit 1; }
    done

    local job_name="aretomo3_${RUN_TAG}"

    submit_and_wait "AreTomo3" \
      sbatch --wait \
        "${SLURM_COMMON_ARGS[@]}" "${SLURM_ARETOMO_ARGS[@]}" \
        --export=ALL \
        --chdir="$BUILD" \
        --job-name="$job_name" \
        --output="$LOG_DIR/${job_name}_%j.out" \
        --error="$LOG_DIR/${job_name}_%j.err" \
        "$SCRIPTS_DIR/run_aretomo3.sbatch" "${DATASETS[@]}"
}

run_missalignment_stage() {
    if [[ "$RUN_MISSALIGNMENT" -ne 1 ]]; then
        echo "RUN_MISSALIGNMENT=0, skipping MissAlignment."
        return
    fi

    [[ -d "$MISSALIGN_ENV" ]] || { echo "ERROR: missing MissAlignment env: $MISSALIGN_ENV"; exit 1; }
    [[ -d "$WARPTOOLS_ENV" ]] || { echo "ERROR: missing WarpTools env: $WARPTOOLS_ENV"; exit 1; }
    [[ -f "$SCRIPTS_DIR/run_missalignment.sbatch" ]] || { echo "ERROR: missing $SCRIPTS_DIR/run_missalignment.sbatch"; exit 1; }

    for d in "${DATASETS[@]}"; do
        required=(
          "$ARETOMO_OUT/$d/$d.mrc"
          "$ARETOMO_OUT/$d/${d}_ODD.mrc"
          "$ARETOMO_OUT/$d/${d}_EVN.mrc"
          "$ARETOMO_OUT/$d/${d}.aln"
          "$ARETOMO_OUT/$d/${d}_TLT.txt"
          "$ARETOMO_OUT/$d/${d}_Imod/${d}_st.xf"
          "$ARETOMO_OUT/$d/${d}_Imod/${d}_st.tlt"
          "$ARETOMO_OUT/$d/${d}_Imod/${d}_st.xtilt"
        )

        for f in "${required[@]}"; do
            [[ -e "$f" ]] || { echo "ERROR: missing AreTomo3 output for MissAlignment: $f"; exit 1; }
        done
    done

    mkdir -p "$MISSALIGN_INPUT" "$MISSALIGN_OUTPUT"
    mkdir -p "$WARP_PROJECT"/{movies,mdoc,alignments,warp_frameseries,warp_tiltseries,tomostar,logs,tmp}

    local job_name="missalignment_${RUN_TAG}"

    submit_and_wait "MissAlignment" \
      sbatch --wait \
        "${SLURM_COMMON_ARGS[@]}" "${SLURM_MISSALIGN_ARGS[@]}" \
        --export=ALL \
        --chdir="$BUILD" \
        --job-name="$job_name" \
        --output="$LOG_DIR/${job_name}_%j.out" \
        --error="$LOG_DIR/${job_name}_%j.err" \
        "$SCRIPTS_DIR/run_missalignment.sbatch" "${DATASETS[@]}"
}

run_warp_reconstruction_stage() {
    if [[ "$RUN_WARP_RECONSTRUCTION" -ne 1 ]]; then
        echo "RUN_WARP_RECONSTRUCTION=0, skipping Warp reconstruction."
        return
    fi

    [[ -f "$SCRIPTS_DIR/run_warp_reconstruction.sbatch" ]] || { echo "ERROR: missing $SCRIPTS_DIR/run_warp_reconstruction.sbatch"; exit 1; }
    [[ -d "$WARP_PROJECT" ]] || { echo "ERROR: missing Warp project: $WARP_PROJECT"; exit 1; }
    [[ -f "$WARP_PROJECT/warp_tiltseries.settings" ]] || { echo "ERROR: missing $WARP_PROJECT/warp_tiltseries.settings"; exit 1; }
    [[ -d "$WARP_PROJECT/warp_tiltseries" ]] || { echo "ERROR: missing $WARP_PROJECT/warp_tiltseries"; exit 1; }
    [[ -d "$WARP_PROJECT/tomostar" ]] || { echo "ERROR: missing $WARP_PROJECT/tomostar"; exit 1; }

    [[ "$WARP_RECON_INPUT" == "$BUILD/"* ]] || { echo "ERROR: unsafe cleanup path" >&2; exit 1; }
    rm -rf -- "$WARP_RECON_INPUT"
    mkdir -p "$WARP_RECON_INPUT" "$WARP_RECON_OUTPUT"

    ln -s "$WARP_PROJECT" "$WARP_RECON_MISSALIGN_PROJECT"
    ln -s "$WARP_PROJECT/warp_tiltseries.settings" "$WARP_RECON_SETTINGS"
    ln -s "$WARP_PROJECT/warp_tiltseries" "$WARP_RECON_INPUT_PROCESSING"
    ln -s "$WARP_PROJECT/tomostar" "$WARP_RECON_TOMOSTAR"

    echo "Warp reconstruction input links:"
    ls -lh "$WARP_RECON_INPUT"
    echo

    local job_name="warp_reconstruction_${RUN_TAG}"

    submit_and_wait "Warp reconstruction" \
      sbatch --wait \
        "${SLURM_COMMON_ARGS[@]}" "${SLURM_WARP_ARGS[@]}" \
        --export=ALL \
        --chdir="$BUILD" \
        --job-name="$job_name" \
        --output="$LOG_DIR/${job_name}_%j.out" \
        --error="$LOG_DIR/${job_name}_%j.err" \
        "$SCRIPTS_DIR/run_warp_reconstruction.sbatch" "${DATASETS[@]}"
}

run_isonet2_stage() {
    if [[ "$RUN_ISONET2" -ne 1 ]]; then
        echo "RUN_ISONET2=0, skipping IsoNet2."
        return
    fi

    [[ -x "$ISONET2_BIN" ]] || { echo "ERROR: IsoNet2 binary not executable: $ISONET2_BIN"; exit 1; }
    [[ -f "$SCRIPTS_DIR/run_isonet2.sbatch" ]] || { echo "ERROR: missing $SCRIPTS_DIR/run_isonet2.sbatch"; exit 1; }

    [[ -d "$WARP_RECON_OUTPUT/tomograms/reconstruction" ]] || {
        echo "ERROR: missing Warp full-tomogram reconstruction folder"
        exit 1
    }
    [[ -d "$WARP_RECON_OUTPUT/tomograms_EVN/reconstruction" ]] || {
        echo "ERROR: missing Warp EVN-tomogram reconstruction folder"
        exit 1
    }
    [[ -d "$WARP_RECON_OUTPUT/tomograms_ODD/reconstruction" ]] || {
        echo "ERROR: missing Warp ODD-tomogram reconstruction folder"
        exit 1
    }
    [[ -d "$ISONET2_WARP_CTF_DIR" ]] || {
        echo "ERROR: missing Warp CTF metadata folder: $ISONET2_WARP_CTF_DIR"
        exit 1
    }

    mkdir -p "$ISONET2_INPUT" "$ISONET2_OUTPUT"

    local job_name="isonet2_${RUN_TAG}"

    submit_and_wait "IsoNet2" \
      sbatch --wait \
        "${SLURM_COMMON_ARGS[@]}" "${SLURM_ISONET2_ARGS[@]}" \
        --export=ALL \
        --chdir="$BUILD" \
        --job-name="$job_name" \
        --output="$LOG_DIR/${job_name}_%j.out" \
        --error="$LOG_DIR/${job_name}_%j.err" \
        "$SCRIPTS_DIR/run_isonet2.sbatch" "${DATASETS[@]}"
}

###############################################################################
# 10. Run workflow
###############################################################################

print_summary


if [[ "$DRY_RUN" -eq 1 ]]; then
    echo
    echo "Dry run: no Slurm jobs will be submitted, files will not be generated."
    for entry in \
      "AreTomo3:SLURM_ARETOMO_ARGS:run_aretomo3.sbatch" \
      "MissAlignment:SLURM_MISSALIGN_ARGS:run_missalignment.sbatch" \
      "Warp reconstruction:SLURM_WARP_ARGS:run_warp_reconstruction.sbatch" \
      "IsoNet2:SLURM_ISONET2_ARGS:run_isonet2.sbatch"; do
      IFS=: read -r label array_name script <<< "$entry"
      printf '  %s: sbatch --wait ' "$label"
      # Print the site-specific arguments that will apply to the stage.
      declare -n stage_args="$array_name"
      printf '%q ' "${SLURM_COMMON_ARGS[@]}" "${stage_args[@]}" \
        --export=ALL --chdir="$BUILD" "$SCRIPTS_DIR/$script" "${DATASETS[@]}"
      printf '\n'
      unset -n stage_args
    done
    exit 0
fi

run_aretomo3_stage
run_missalignment_stage
run_warp_reconstruction_stage
run_isonet2_stage

echo
echo "============================================================"
echo "Whole pipeline finished successfully"
echo "End time: $(date)"
echo "============================================================"
