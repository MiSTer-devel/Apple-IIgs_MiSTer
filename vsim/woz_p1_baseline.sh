#!/usr/bin/env bash
# P1 (TMAP redundant-reload) baseline. Counts BRAM track loads vs actual
# physical track changes per boot. The P1 fix should drive `loads` down
# toward `phys` while the boot screenshot hash stays identical.
# Usage: ./woz_p1_baseline.sh <frames> <out.csv> <disk> [disk...]
F="$1"; OUT="$2"; shift 2
echo "disk,loads,phys,seeks,redundant,pct_redundant" > "$OUT"
for d in "$@"; do
  log=$(timeout 600 ./obj_dir/Vemu --no-cpu-log --woz "disks_525/$d" \
        --stop-at-frame "$F" 2>&1 | grep -E 'starting load for track|Physical track changed|Seek request')
  l=$(grep -c 'starting load for track' <<<"$log")
  p=$(grep -c 'Physical track changed' <<<"$log")
  s=$(grep -c 'Seek request' <<<"$log")
  r=$(( l - p ))
  pct=$(python3 -c "print('%.0f'%(100*$r/$l) if $l else '0')" 2>/dev/null || echo 0)
  printf '"%s",%d,%d,%d,%d,%s\n' "$d" "$l" "$p" "$s" "$r" "$pct" >> "$OUT"
  printf '  %-42s loads=%-4d phys=%-4d redundant=%-4d (%s%%)\n' "${d:0:42}" "$l" "$p" "$r" "$pct"
done
