#!/usr/bin/env bash
# Run boltz2 prediction (with affinity + embeddings) on every WT ligand
# across all targets in Boltz_ligands/, parallelized across local GPUs.
#
# Output layout: Boltz_output/<TARGET>/predictions/<ZINC_ID>/...
# Boltz skips predictions whose affinity_<id>.json already exists, so
# re-running is safe and resumable.

set -euo pipefail

ROOT="/work/jwang/boltz2"
LIG_DIR="${ROOT}/Boltz_ligands"
OUT_DIR="${ROOT}/Boltz_output"
LOG_DIR="${OUT_DIR}/_logs"
GPUS=(0 1 2 3)                  # 4 RTX 6000 Ada cards
MAX_JOBS=${#GPUS[@]}

mkdir -p "${OUT_DIR}" "${LOG_DIR}"

# Pick up targets that have a wt/input directory (skip mut, shuffled).
mapfile -t TARGETS < <(
    for d in "${LIG_DIR}"/*/; do
        t=$(basename "$d")
        [[ -d "${d}/wt/input" ]] && echo "$t"
    done
)

echo "Targets to run: ${TARGETS[*]}"
echo "GPUs available: ${GPUS[*]}"
echo "Output dir:     ${OUT_DIR}"
echo

run_target() {
    local target="$1"
    local gpu="$2"
    local in_dir="${LIG_DIR}/${target}/wt/input"
    local out_dir="${OUT_DIR}/${target}"
    local log="${LOG_DIR}/${target}.log"

    mkdir -p "${out_dir}"
    echo "[$(date '+%H:%M:%S')] GPU ${gpu} -> ${target} (log: ${log})"

    CUDA_VISIBLE_DEVICES="${gpu}" boltz predict \
        "${in_dir}" \
        --out_dir "${out_dir}" \
        --output_format pdb \
        --use_msa_server \
        --write_embeddings \
        --num_workers 2 \
        > "${log}" 2>&1
}

# Simple per-GPU dispatcher: keep a PID per GPU slot, refill when one finishes.
declare -A SLOT_PID
declare -A SLOT_TARGET
ti=0
n=${#TARGETS[@]}

while (( ti < n )) || (( ${#SLOT_PID[@]} > 0 )); do
    # Launch into any free slot.
    for gpu in "${GPUS[@]}"; do
        if (( ti >= n )); then break; fi
        if [[ -z "${SLOT_PID[$gpu]:-}" ]]; then
            target="${TARGETS[$ti]}"
            run_target "$target" "$gpu" &
            SLOT_PID[$gpu]=$!
            SLOT_TARGET[$gpu]="$target"
            ti=$((ti + 1))
        fi
    done

    # Wait for any one slot to finish, then free it.
    if (( ${#SLOT_PID[@]} > 0 )); then
        wait -n || true
        for gpu in "${!SLOT_PID[@]}"; do
            pid="${SLOT_PID[$gpu]}"
            if ! kill -0 "$pid" 2>/dev/null; then
                wait "$pid" 2>/dev/null && rc=0 || rc=$?
                tgt="${SLOT_TARGET[$gpu]}"
                if (( rc == 0 )); then
                    echo "[$(date '+%H:%M:%S')] GPU ${gpu} <- ${tgt}: OK"
                else
                    echo "[$(date '+%H:%M:%S')] GPU ${gpu} <- ${tgt}: FAILED (rc=${rc}, see ${LOG_DIR}/${tgt}.log)"
                fi
                unset 'SLOT_PID[$gpu]'
                unset 'SLOT_TARGET[$gpu]'
            fi
        done
    fi
done

echo
echo "All targets done. Outputs in: ${OUT_DIR}"
