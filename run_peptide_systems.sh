#!/bin/bash
# Run Boltz-2 structure prediction + embedding export over the peptide_systems
# SKEMPI inputs, one system per GPU, refilling GPU slots as systems finish.
#
# These inputs are STRUCTURE-ONLY: every chain is `msa: empty` and no affinity
# block is present, so we do NOT use the MSA server and do NOT expect an
# affinity JSON. `--write_embeddings` saves the trunk s/z that _build_aff_emb.py
# needs for post-hoc affinity-embedding reconstruction.
#
# Usage:
#   bash run_peptide_systems.sh                 # all 13 systems
#   bash run_peptide_systems.sh 1VFB_AB_C       # one system (smoke test)
#   bash run_peptide_systems.sh 3SE3_B_A 1GC1_G_C   # a subset
#
# Config below is set for yuan; change BOLTZ_BIN / GPUS / CACHE for another node
# (e.g. on clickff use only the free GPU indices).
set -u

# ---- config -----------------------------------------------------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # this peptide_systems/ dir
IN_ROOT="${ROOT}/boltz_inputs"
OUT="${ROOT}/_output"
LOG_DIR="${ROOT}/_logs"
ISSUES="${ROOT}/run_issues.txt"
CACHE="${HOME}/.boltz"
BOLTZ_BIN="/home/juw79/.local/bin/boltz"   # imports the patched /work/jwang/boltz2/boltz
GPUS=(0 1 2 3)                              # <-- set to the FREE GPU indices on this node
NUM_GPUS=${#GPUS[@]}
# -----------------------------------------------------------------------------

mkdir -p "${OUT}" "${LOG_DIR}"

# amber22 python paths break pytorch-lightning's MPI probe -> clear them
unset PYTHONPATH
unset LD_LIBRARY_PATH

log_issue () { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [run] $*" | tee -a "${ISSUES}"; }

# Systems = CLI args if given, else every subdir of boltz_inputs/ that has input/.
if (( $# > 0 )); then
    SYSTEMS=("$@")
else
    mapfile -t SYSTEMS < <(for d in "${IN_ROOT}"/*/; do
                               s=$(basename "$d")
                               [ -d "${d}input" ] && echo "$s"
                           done | sort)
fi

# Order smallest-first (fewest YAMLs) so quick systems clear and fan out fast.
mapfile -t SYSTEMS < <(for s in "${SYSTEMS[@]}"; do
                           n=$(ls "${IN_ROOT}/${s}/input"/*.yaml 2>/dev/null | wc -l)
                           echo "$n $s"
                       done | sort -n | awk '{print $2}')

echo "Systems (small first): ${SYSTEMS[*]}"
echo "Output:  ${OUT}"
echo "GPUs:    ${GPUS[*]}"
echo "Boltz:   ${BOLTZ_BIN}"
echo

run_one () {
    local sys="$1" gpu="$2"
    local in_dir="${IN_ROOT}/${sys}/input"
    local out_dir="${OUT}/${sys}"
    local log="${LOG_DIR}/${sys}.log"
    mkdir -p "${out_dir}"
    local n; n=$(ls "${in_dir}"/*.yaml 2>/dev/null | wc -l)
    echo "[$(date '+%H:%M:%S')] START ${sys} on GPU ${gpu} (${n} yamls)"
    CUDA_VISIBLE_DEVICES="${gpu}" \
    "${BOLTZ_BIN}" predict "${in_dir}" \
        --out_dir "${out_dir}" \
        --cache "${CACHE}" \
        --output_format pdb \
        --write_embeddings \
        --num_workers 2 \
        > "${log}" 2>&1
    local rc=$?
    echo "[$(date '+%H:%M:%S')] END   ${sys} on GPU ${gpu} rc=${rc}"
    (( rc != 0 )) && log_issue "${sys}: boltz exited rc=${rc} (GPU ${gpu}); see _logs/${sys}.log"
    return $rc
}

# Fan out across GPUs, refilling a slot whenever a system finishes.
declare -A SLOT_PID SLOT_SYS
next=0; total=${#SYSTEMS[@]}

for i in $(seq 0 $((NUM_GPUS-1))); do
    (( next >= total )) && break
    run_one "${SYSTEMS[$next]}" "${GPUS[$i]}" &
    SLOT_PID[$i]=$!; SLOT_SYS[$i]="${SYSTEMS[$next]}"; next=$((next+1))
done

while (( ${#SLOT_PID[@]} > 0 )); do
    wait -n
    for i in "${!SLOT_PID[@]}"; do
        if ! kill -0 "${SLOT_PID[$i]}" 2>/dev/null; then
            unset 'SLOT_PID[$i]' 'SLOT_SYS[$i]'
            if (( next < total )); then
                run_one "${SYSTEMS[$next]}" "${GPUS[$i]}" &
                SLOT_PID[$i]=$!; SLOT_SYS[$i]="${SYSTEMS[$next]}"; next=$((next+1))
            fi
        fi
    done
done

echo
echo "[$(date '+%H:%M:%S')] All systems complete. Outputs under ${OUT}/<system>/"
echo "Next: python _build_aff_emb.py   # reconstruct affinity embeddings"
