#!/usr/bin/env bash
# tests/qa_ground_truth.sh OUTDIR — independent ground truth: a 0.25 s external sampler records every
# process of the test user while the service (DEFAULT settings, INTERVAL_SEC=5) runs; afterwards the
# sampler's view is compared with processes.csv: missed processes, start/end errors, duplicates.
set -u -o pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
OUT=${1:?usage: qa_ground_truth.sh OUTDIR}; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd -P)
# shellcheck source=/dev/null
source "$ROOT/tests/usermgr.sh"
cleanup() { um_run pkill -KILL -u "$UM_USER" 2>/dev/null; um_cleanup; }
trap cleanup EXIT
um_detect && um_setup "$OUT" || { echo "no user manager"; exit 2; }
P="$UM_HOME/Computer-Activity-Logger"; M() { um_run "$P/main.sh" "$@"; }
git clone -q "$ROOT" "$P" 2>/dev/null; chown -R "$UM_USER" "$P";
M consent --accept >/dev/null; M service install >/dev/null; M service enable >/dev/null; M service start
um_run bash -c 'setsid nohup Xvfb :98 -screen 0 1280x800x24 >/dev/null 2>&1 &'; sleep 2
# the independent sampler (runs as the same user, outside the logger)
um_run bash -c 'setsid nohup bash -c "while :; do now=\$(date +%s.%N); ps -u \$(id -u) -o pid=,etimes=,comm= | while read -r p e c; do echo \"\$now \$p \$e \$c\"; done; sleep 0.25; done" >"'"$UM_HOME"'/sampler.log" 2>&1 &'
sleep 3
L() { um_run env DISPLAY=:98 bash -c 'setsid nohup "$@" >/dev/null 2>&1 & echo $!' _ "$@"; }
t0=$(date +%s)
CH=$(L google-chrome --no-sandbox --no-first-run --disable-gpu --user-data-dir="$UM_HOME/cp" about:blank); sleep 6
X1=$(L xterm -e sleep 14); sleep 4
X2=$(L xterm -e sleep 40); sleep 4
for i in 1 2 3; do um_run sleep 8 & done; sleep 3                      # 8 s helpers
for i in 1 2 3 4 5; do um_run sleep 2; done                            # 2 s processes (below the 5 s interval)
sleep 12
um_run kill -TERM "$CH"; sleep 12
M service stop
sleep 1; um_run pkill -f 'while :; do now' 2>/dev/null; um_run pkill -KILL -f sampler 2>/dev/null
cp "$UM_HOME/sampler.log" "$OUT/sampler.log"; cp "$P/data/processes.csv" "$OUT/processes.csv"; cp "$P/data/sessions.csv" "$OUT/sessions.csv"
# ---- compare
echo "sampler lines: $(wc -l < "$OUT/sampler.log")"
# build ground truth table: pid, comm, start_epoch(observed), first_seen, last_seen
awk '{ k=$2 SUBSEP int($1-$3+0.5); if(!(k in f)){f[k]=$1; s[k]=$1-$3; c[k]=$4; p[k]=$2} l[k]=$1 }
     END{ for(k in f) printf "%s\t%s\t%.0f\t%.2f\t%.2f\n", p[k], c[k], s[k], f[k], l[k] }' "$OUT/sampler.log" | sort -n > "$OUT/truth.tsv"
tr -d '\r' < "$OUT/processes.csv" | sed '1s/^\xEF\xBB\xBF//' | tail -n +2 | awk -F, '{ gsub(/"/,"",$3); print $2 "\t" $3 "\t" $5 "\t" $6 "\t" $7 "\t" $8 }' > "$OUT/csv.tsv"
echo "ground-truth processes: $(wc -l < "$OUT/truth.tsv")   csv rows: $(wc -l < "$OUT/csv.tsv")"
echo "--- processes seen by the sampler living >= 7 s (must all be in processes.csv):"
miss=0
while IFS=$'\t' read -r pid comm st fs ls; do
    life=$(awk -v a="$fs" -v b="$ls" 'BEGIN{printf "%.1f", b-a}')
    if awk -v l="$life" 'BEGIN{exit !(l>=7)}'; then
        if awk -F'\t' -v p="$pid" -v c="$comm" '$1==p && $2==c {f=1} END{exit !f}' "$OUT/csv.tsv"; then :; else
            case $comm in ps|bash|date|id) ;; *) echo "  MISSED pid=$pid $comm life=${life}s"; miss=$((miss+1)) ;; esac
        fi
    fi
done < "$OUT/truth.tsv"
echo "missed (>=7 s): $miss"
echo "--- 2-second processes: sampler saw $(awk -F'\t' '$2=="sleep"{l=$5-$4; if(l<3) n++} END{print n+0}' "$OUT/truth.tsv") short sleeps (<3 s); csv has $(awk -F'\t' '$2=="sleep" && $5<=6' "$OUT/csv.tsv" | wc -l) sleep rows with duration<=6"
echo "--- accuracy for matched processes (CSV vs sampler):  start_err = csv_start - observed_start; end_lag = csv_end - last_seen"
while IFS=$'\t' read -r pid comm cs ce cd cst; do
    row=$(awk -F'\t' -v p="$pid" -v c="$comm" '$1==p && $2==c' "$OUT/truth.tsv" | head -n1)
    [[ -n $row ]] || continue
    IFS=$'\t' read -r _ _ ts _ tl <<<"$row"
    s=$(date -u -d "$cs" +%s); e=$(date -u -d "$ce" +%s)
    printf '%s\t%s\t%s\t%s\t%s\n' "$comm" "$pid" "$((s - ts))" "$(awk -v e="$e" -v l="$tl" 'BEGIN{printf "%.1f", e-l}')" "$cst"
done < "$OUT/csv.tsv" > "$OUT/accuracy.tsv"
awk -F'\t' '{ n++; se=$3; if(se<0)se=-se; if(se>mxs)mxs=se; if($4>mxl)mxl=$4; if($4<mnl||n==1)mnl=$4 }
 END{ printf "matched=%d  max|start_err|=%d s   end_lag min=%.1f max=%.1f s\n", n, mxs, mnl, mxl }' "$OUT/accuracy.tsv"
echo "--- duplicates in processes.csv (Session,PID,Start): $(awk -F, 'NR>1{k=$1"|"$2"|"$5; c[k]++} END{n=0; for(k in c) if(c[k]>1) n++; print n}' "$OUT/processes.csv")"
echo "--- user/column checks: usernames in csv: $(awk -F, 'NR>1{gsub(/"/,"",$4); print $4}' "$OUT/processes.csv" | sort -u | tr '\n' ' ') expected $UM_USER"
M processes --check; M sessions --check
echo GT_DONE
