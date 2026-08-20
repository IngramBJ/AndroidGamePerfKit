#!/system/bin/sh
# AndroidGamePerfKit lightweight sampler. No root and no Perfetto required.
PKG="$1"
INTERVAL="$2"
OUT="$3"
STOP="$4"
MAX_SECONDS="${5:-14400}"
CLOCK_TICKS=$(getconf CLK_TCK 2>/dev/null)
case "$CLOCK_TICKS" in ''|*[!0-9]*) CLOCK_TICKS=100 ;; esac
START_UPTIME=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)

printf 'uptime_s\tpid\tproc_ticks\tmain_ticks\tunity_ticks\tgfx_ticks\tjob_ticks\trss_kb\tmem_available_kb\tswap_total_kb\tswap_free_kb\tcpu_freq_avg_khz\tthermal_max_mc\tbattery_pct\tclock_ticks_per_sec\n' > "$OUT"

sum_thread_ticks() {
  target="$1"
  kind="$2"
  total=0
  for task in /proc/$target/task/[0-9]*; do
    [ -r "$task/comm" ] || continue
    name=$(cat "$task/comm" 2>/dev/null)
    take=0
    case "$kind:$name" in
      unity:UnityMain*) take=1 ;;
      gfx:UnityGfxDeviceW*) take=1 ;;
      job:Job.Worker*|job:Worker*) take=1 ;;
    esac
    if [ "$take" = "1" ] && [ -r "$task/stat" ]; then
      ticks=$(awk '{print $14+$15}' "$task/stat" 2>/dev/null)
      total=$((total + ${ticks:-0}))
    fi
  done
  echo "$total"
}

while [ ! -e "$STOP" ]; do
  uptime_s=$(awk '{print $1}' /proc/uptime 2>/dev/null)
  uptime_int=${uptime_s%%.*}
  if [ $((uptime_int - START_UPTIME)) -ge "$MAX_SECONDS" ]; then break; fi
  pid=$(pidof "$PKG" 2>/dev/null | awk '{print $1}')
  proc_ticks=0; main_ticks=0; unity_ticks=0; gfx_ticks=0; job_ticks=0; rss_kb=0
  if [ -n "$pid" ] && [ -r "/proc/$pid/stat" ]; then
    proc_ticks=$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null)
    main_ticks=$(awk '{print $14+$15}' "/proc/$pid/task/$pid/stat" 2>/dev/null)
    rss_kb=$(awk '/^VmRSS:/ {print $2; exit}' "/proc/$pid/status" 2>/dev/null)
    unity_ticks=$(sum_thread_ticks "$pid" unity)
    gfx_ticks=$(sum_thread_ticks "$pid" gfx)
    job_ticks=$(sum_thread_ticks "$pid" job)
  fi

  mem_available_kb=$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null)
  swap_total_kb=$(awk '/^SwapTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null)
  swap_free_kb=$(awk '/^SwapFree:/ {print $2; exit}' /proc/meminfo 2>/dev/null)

  freq_sum=0; freq_count=0
  for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq; do
    [ -r "$f" ] || continue
    v=$(cat "$f" 2>/dev/null)
    case "$v" in ''|*[!0-9]*) ;; *) freq_sum=$((freq_sum + v)); freq_count=$((freq_count + 1));; esac
  done
  if [ "$freq_count" -gt 0 ]; then cpu_freq_avg_khz=$((freq_sum / freq_count)); else cpu_freq_avg_khz=0; fi

  thermal_max_mc=0
  for t in /sys/class/thermal/thermal_zone*/temp; do
    [ -r "$t" ] || continue
    v=$(cat "$t" 2>/dev/null)
    case "$v" in
      ''|*[!0-9-]*) ;;
      *)
        if [ "$v" -gt 0 ] && [ "$v" -le 200 ]; then v=$((v * 1000)); fi
        if [ "$v" -gt 1000 ] && [ "$v" -lt 200000 ] && [ "$v" -gt "$thermal_max_mc" ]; then thermal_max_mc="$v"; fi
        ;;
    esac
  done
  battery_pct=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${uptime_s:-0}" "${pid:-}" "${proc_ticks:-0}" "${main_ticks:-0}" "${unity_ticks:-0}" "${gfx_ticks:-0}" "${job_ticks:-0}" \
    "${rss_kb:-0}" "${mem_available_kb:-0}" "${swap_total_kb:-0}" "${swap_free_kb:-0}" "${cpu_freq_avg_khz:-0}" "${thermal_max_mc:-0}" "${battery_pct:-}" "$CLOCK_TICKS" >> "$OUT"
  sleep "$INTERVAL"
done
