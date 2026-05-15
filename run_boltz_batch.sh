#!/bin/bash
# Run boltz2 predict on every wt/input set in Boltz_ligands/, in parallel across GPUs.
# Outputs go to Boltz_output/<TARGET>/. Embeddings are written via --write_embeddings.
# Ligands that already have an output folder are skipped (default boltz behavior, no --override).

set -u

# --- config ---
ROOT="/work/jwang/boltz2"
# Original ligand yamls live under Boltz_ligands/<TARGET>/wt/input/,
# but some have malformed YAML (multi-line sequence in CASR; missing space
# after `sequence:` in CNR1). sanitize_inputs.py writes cleaned copies to
# this tree, which is what we feed to boltz.
LIG_DIR="${ROOT}/Boltz_output/_fixed_inputs"
OUT_ROOT="${ROOT}/Boltz_output"
LOG_DIR="${OUT_ROOT}/_logs"
CACHE="${HOME}/.boltz"
GPUS=(0 1 2 3)
NUM_GPUS=${#GPUS[@]}

mkdir -p "${OUT_ROOT}" "${LOG_DIR}"

# --- environment ---
# NOTE: do NOT `conda activate boltz` — that env's boltz binary points at a
# different install (/work/hat170/aptamer/boltz). The bare `boltz` on PATH
# (~/.local/bin/boltz, base python) imports from /work/jwang/boltz2/boltz/
# which has the patched affinity.py that writes embeddings.
BOLTZ_BIN="/home/juw79/.local/bin/boltz"

# Clear inherited paths that point at amber22's python 3.10 site-packages.
# Without this, pytorch-lightning's accelerator probe tries `from mpi4py
# import MPI` against the amber22 mpi4py (built for py3.10) and crashes on
# import inside the py3.12 base python.
unset PYTHONPATH
unset LD_LIBRARY_PATH

# --- collect targets ---
TARGETS=()
for d in "${LIG_DIR}"/*/; do
    name=$(basename "$d")
    # skip our own logs/output bookkeeping dirs
    [[ "$name" == _* ]] && continue
    if compgen -G "${d}*.yaml" > /dev/null; then
        TARGETS+=("$name")
    fi
done

echo "Targets to process (${#TARGETS[@]}): ${TARGETS[*]}"
echo "Output root: ${OUT_ROOT}"
echo "Cache:       ${CACHE}"
echo "GPUs:        ${GPUS[*]}"
echo

run_one () {
    local target="$1"
    local gpu="$2"
    local in_dir="${LIG_DIR}/${target}"
    local out_dir="${OUT_ROOT}/${target}"
    local log="${LOG_DIR}/${target}.log"

    mkdir -p "${out_dir}"
    echo "[$(date '+%H:%M:%S')] START ${target} on GPU ${gpu}  (log: ${log})"

    CUDA_VISIBLE_DEVICES="${gpu}" \
    "${BOLTZ_BIN}" predict "${in_dir}" \
        --out_dir "${out_dir}" \
        --cache "${CACHE}" \
        --output_format pdb \
        --use_msa_server \
        --write_embeddings \
        > "${log}" 2>&1

    local rc=$?
    echo "[$(date '+%H:%M:%S')] END   ${target} on GPU ${gpu}  rc=${rc}"
    return $rc
}

# --- parallel scheduler: at most NUM_GPUS targets running at once ---
declare -A SLOT_PID  # gpu_index -> pid
declare -A SLOT_TGT  # gpu_index -> target

next_target_idx=0
total=${#TARGETS[@]}

# launch initial round
for i in $(seq 0 $((NUM_GPUS - 1))); do
    if (( next_target_idx >= total )); then break; fi
    target="${TARGETS[$next_target_idx]}"
    gpu="${GPUS[$i]}"
    run_one "$target" "$gpu" &
    SLOT_PID[$i]=$!
    SLOT_TGT[$i]="$target"
    next_target_idx=$((next_target_idx + 1))
done

# refill slots as jobs finish
while (( ${#SLOT_PID[@]} > 0 )); do
    # wait for any background job to finish
    wait -n
    # find which slot's pid is no longer running and refill
    for i in "${!SLOT_PID[@]}"; do
        pid=${SLOT_PID[$i]}
        if ! kill -0 "$pid" 2>/dev/null; then
            unset 'SLOT_PID[$i]'
            unset 'SLOT_TGT[$i]'
            if (( next_target_idx < total )); then
                target="${TARGETS[$next_target_idx]}"
                gpu="${GPUS[$i]}"
                run_one "$target" "$gpu" &
                SLOT_PID[$i]=$!
                SLOT_TGT[$i]="$target"
                next_target_idx=$((next_target_idx + 1))
            fi
        fi
    done
done

echo
echo "All targets complete. Outputs under ${OUT_ROOT}/<TARGET>/boltz_results_input/predictions/<ZINC_ID>/"
