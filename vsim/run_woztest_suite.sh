#!/usr/bin/env bash
# Run the Applesauce WOZ Test Images through Vemu.
# Each image isolates one floppy behaviour; see WozTestImages/readme.txt.
OUT="${1:-woztest_results}"; FRAMES="${2:-1500}"; JOBS="${3:-12}"
mkdir -p "$OUT/shots"; CSV="$OUT/results.csv"
echo "status,png_size,png_hash,seconds,rc,image" > "$CSV"
run_one() {
  local w="$1" shot rc sz hash st
  shot="$OUT/shots/$(basename "$w" .woz | tr ' /' '__').png"
  timeout 900 ./obj_dir/Vemu --quiet --no-cpu-log --fixed-time \
      --woz "$w" --stop-at-frame "$FRAMES" --screenshot "$FRAMES" \
      --screenshot-name "$shot" >/dev/null 2>&1
  rc=$?
  if [[ -f "$shot" ]]; then
    sz=$(stat -c%s "$shot"); hash=$(md5sum "$shot"|awk '{print $1}')
    if   [[ $rc -eq 124 || $rc -eq 137 ]]; then st=TIMEOUT
    elif [[ $sz -lt 5600 ]]; then st=BLANK
    elif [[ $sz -lt 6500 ]]; then st=TEXT_ONLY
    else st=BOOTED; fi
  else sz=0; hash=""; st=$([[ $rc -eq 124 || $rc -eq 137 ]] && echo TIMEOUT || echo CRASH); fi
  printf '%s,%d,%s,0,%d,"%s"\n' "$st" "$sz" "$hash" "$rc" "$(basename "$w")" >> "$CSV"
  printf '  %-10s %-52s\n' "$st" "$(basename "$w" .woz)"
}
export -f run_one; export OUT FRAMES CSV
ls woztest_suite/*.woz | tr '\n' '\0' | xargs -0 -P "$JOBS" -I{} bash -c 'run_one "$@"' _ {}
echo; echo "=== summary ==="; awk -F',' 'NR>1{c[$1]++} END{for(s in c) printf "  %-10s %d\n",s,c[s]}' "$CSV"
