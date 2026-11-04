#!/usr/bin/env bash
# Copy this template to a private config.sh outside the Git checkout.
# Run: bash pipeline.sh --config=/path/to/private/config.sh
# Files in this example are placeholders, NOT acquisition metadata or validated scientific settings.

# Required absolute paths. Keep RUN_DIR outside the public Git checkout.
RUN_DIR=""                           # e.g. /your/private/work/runs/run_001
DATA_ROOT=""                         # directory with tiltseries_001/, tiltseries_002/, etc.
DATASETS=("tiltseries_001")          # synthetic example; replace with real directory basenames
GAIN_FILE=""                         # absolute path to your detector gain reference
ARETOMO3=""                          # executable path
WARPTOOLS_ENV=""                     # absolute conda environment path
MISSALIGN_ENV=""                     # absolute conda environment path
ISONET2_ENV=""                       # absolute conda environment path
# ISONET2_BIN="$ISONET2_ENV/bin/isonet.py" # auto-derived unless overridden

# Slurm: adapt queue/account/constraint/resources to your site's hardware.
# Current GPU counts reflect the workflow's existing allocations, not universal requirements.
SLURM_COMMON_ARGS=(--partition=YOUR_GPU_PARTITION)  # add --account=... etc if needed
SLURM_ARETOMO_ARGS=(--time=08:00:00 --nodes=1 --ntasks=1 --cpus-per-task=4 --gres=gpu:1 --mem=128G)
SLURM_MISSALIGN_ARGS=(--time=24:00:00 --nodes=1 --ntasks=1 --cpus-per-task=16 --gres=gpu:4 --mem=128G)
SLURM_WARP_ARGS=(--time=08:00:00 --nodes=1 --ntasks=1 --cpus-per-task=16 --gres=gpu:1 --mem=128G)
SLURM_ISONET2_ARGS=(--time=24:00:00 --nodes=1 --ntasks=1 --cpus-per-task=32 --gres=gpu:4 --mem=256G)
# CLUSTER_INIT="/path/to/cluster_init.sh"   # optional module/conda setup; not committed
# CONDA_SH="/path/to/conda/etc/profile.d/conda.sh"
# ARETOMO_CUDA_MODULE="your_site_cuda_module" # optional module name for AreTomo3
ARETOMO_MODULE_PURGE=0
ARETOMO_GPU_ID=0
SCRATCH_SYMLINK_PARENT="/tmp"         # set only to a directory with short writable paths

# Required per-acquisition microscope and reconstruction parameters; no real dataset values supplied.
PIX_SIZE=""             # original input pixel size, Angstroms
KV=""                   # accelerating voltage, kV
CS=""                   # spherical aberration, mm
DOSE_PER_TILT=""        # e-/A^2/tilt
EER_FRAMES_PER_TILT=""  # raw detector frames per tilt
TILT_AXIS=""            # nominal tilt axis, degrees
VOLZ=""                 # reconstruction depth in pixels
TOMO_DIMENSIONS=""      # e.g. XxYxZ at input sampling; must match your data
WARP_RECON_ANGPIX=""    # desired reconstruction pixel size, Angstroms
FM_INT=12               # integration frames, adjust for acquisition

# Algorithm defaults from the supplied pipeline; review for your own data.
EER_SAMPLING=1
MC_BIN=1
MCPATCH_X=5
MCPATCH_Y=5
GROUP_GLOBAL=2
GROUP_LOCAL=4
TILT_AXIS_REFINE=1
ATBIN=4
WBP=1
FLIP_GAIN=1
FLIP_VOL=1
TILT_COR=1
OUT_IMOD=1
SPLIT_SUM=1
DARK_TOL=0.7
ATPATCH_X=4
ATPATCH_Y=4
CORR_CTF=1
AMP_CONTRAST=0.1

# Pipeline stages. Set 0 to reuse outputs; read docs before resuming.
RUN_ARETOMO3=1
RUN_MISSALIGNMENT=1
RUN_WARP_RECONSTRUCTION=1
RUN_ISONET2=1

# MissAlignment original training schedule / GPU assignment.
MISS_PREPARE_STACKS=10.0
MISS_TRAINING_DEVICES=0,1
MISS_RECONSTRUCTION_DEVICES=2,2,2,3,3,3
MISS_DATALOADERS_PER_TRAINER=5
MISS_START_AT_ITERATION=0
MISS_BATCH_SIZE=16
REBUILD_WARP_PROJECT=1

# WarpTools reconstruction; full/odd/even stacks are expected for IsoNet2.
WARP_RECON_RUN_CTF=1
WARP_CTF_RANGE_HIGH=7
WARP_CTF_DEFOCUS_MAX=8
WARP_RECON_PERDEVICE=1
WARP_RECON_HALF_MAPS=1
WARP_RECON_FORCE_FLOAT32=0
WARP_RECON_DONT_INVERT=1

# IsoNet2 workflow.
ISONET2_INPUT_MODE=even_odd
ISONET2_NUMBER_SUBTOMOS=100
ISONET2_CLEAN_STAGE_OUTPUTS=1
ISONET2_CTF_NEIGHBOR_COUNT=4
ISONET2_CTF_MAX_DEVIATION_UM=0.75
ISONET2_CTF_MAX_DEVIATION_FRACTION=0.20
ISONET2_RUN_PREPARE_STAR=1
ISONET2_RUN_INITIAL_REFINE=1
ISONET2_RUN_INITIAL_PREDICT=1
ISONET2_RUN_MAKE_MASK=1
ISONET2_RUN_FINAL_REFINE=1
ISONET2_RUN_FINAL_PREDICT=1
ISONET2_GPU_ID=0,1,2,3
ISONET2_NCPUS=32
ISONET2_ARCH=unet-medium
ISONET2_BATCH_SIZE=auto
ISONET2_METHOD=isonet2-n2n
ISONET2_CTF_MODE=network
ISONET2_BFACTOR=0
ISONET2_INITIAL_REFINE_CUBE_SIZE=96
ISONET2_INITIAL_REFINE_EPOCHS=50
ISONET2_INITIAL_REFINE_MW_WEIGHT=20
ISONET2_MASK_INPUT_COLUMN=rlnCorrectedTomoName
ISONET2_MASK_DENSITY_PERCENTAGE=50
ISONET2_MASK_STD_PERCENTAGE=50
ISONET2_MASK_Z_CROP=0.2
ISONET2_FINAL_REFINE_CUBE_SIZE=128
ISONET2_FINAL_REFINE_EPOCHS=100
ISONET2_FINAL_REFINE_MW_WEIGHT=200
