$a=@($args)
if($a.Count -ge 2 -and $a[0] -eq '-s'){$a=$a[2..($a.Count-1)]}
if($a.Count -eq 0){exit 0}

if($a[0] -eq 'devices'){
    "List of devices attached"
    "MOCK123`tdevice"
    exit 0
}
if($a[0] -eq 'version'){'Android Debug Bridge version 1.0.41';exit 0}
if($a[0] -eq 'push'){'1 file pushed, 0 skipped.';exit 0}
if($a[0] -eq 'pull'){
    $remote=$a[1];$local=$a[2]
    $parent=Split-Path -Parent $local;if($parent){New-Item -ItemType Directory -Force -Path $parent|Out-Null}
    if($remote -match 'samples'){
        @"
uptime_s	pid	proc_ticks	main_ticks	unity_ticks	gfx_ticks	job_ticks	rss_kb	mem_available_kb	swap_total_kb	swap_free_kb	cpu_freq_avg_khz	thermal_max_mc	battery_pct	clock_ticks_per_sec
100.0	1234	1000	400	300	100	100	524288	2097152	6291452	4194304	1800000	43000	80	100
101.0	1234	1120	455	345	115	120	532480	2080000	6291452	4180000	1900000	44000	80	100
102.0	1234	1240	510	390	130	140	540672	2070000	6291452	4170000	2000000	45000	79	100
"@ | Set-Content -LiteralPath $local -Encoding UTF8
    } else {'mock sampler log'|Set-Content -LiteralPath $local -Encoding UTF8}
    '1 file pulled.';exit 0
}
if($a[0] -eq 'logcat'){
    if($a -contains '-d'){'08-19 12:00:00.000  1234  1234 I Mock: logcat'}
    exit 0
}
if($a[0] -eq 'shell'){
    $cmd=($a[1..($a.Count-1)] -join ' ')
    switch -Regex ($cmd){
        '^getprop$' {'[ro.product.model]: [Mock Phone]';exit 0}
        '^getprop ro.build.version.sdk$' {'34';exit 0}
        '^getprop ro.product.manufacturer$' {'MockCorp';exit 0}
        '^getprop ro.product.model$' {'Mock Phone';exit 0}
        '^wm size$' {'Physical size: 1080x2400';exit 0}
        '^dumpsys input$' {'SurfaceOrientation: 0';exit 0}
        '^dumpsys display$' {'mCurrentOrientation=0';exit 0}
        '^settings get system user_rotation$' {'0';exit 0}
        '^dumpsys activity activities$' {'mResumedActivity: ActivityRecord{123 u0 com.example.game/com.example.game.MainActivity t1}';exit 0}
        '^getevent -lp$' {@'
add device 1: /dev/input/event6
  name:     "mock-touchscreen"
  events:
    ABS (0003):
      ABS_MT_POSITION_X : value 0, min 0, max 1079, fuzz 0, flat 0, resolution 0
      ABS_MT_POSITION_Y : value 0, min 0, max 2399, fuzz 0, flat 0, resolution 0
'@;exit 0}
        '^getevent -lt /dev/input/event6$' {@'
[  200.100000] /dev/input/event6: EV_ABS       ABS_MT_TRACKING_ID   00000031
[  200.100100] /dev/input/event6: EV_ABS       ABS_MT_POSITION_X    0000021c
[  200.100200] /dev/input/event6: EV_ABS       ABS_MT_POSITION_Y    000004b0
[  200.180000] /dev/input/event6: EV_ABS       ABS_MT_TRACKING_ID   ffffffff
[  200.180100] /dev/input/event6: EV_SYN       SYN_REPORT           00000000
'@;exit 0}
        '^pm path ' {'package:/data/app/mock/base.apk';exit 0}
        '^pidof ' {'1234';exit 0}
        '^cat /proc/meminfo$' {@'
MemTotal:        8388608 kB
MemAvailable:    2097152 kB
SwapTotal:       6291452 kB
SwapFree:        4194304 kB
'@;exit 0}
        '^df -k /data$' {@'
Filesystem     1K-blocks     Used Available Use% Mounted on
/dev/mock       67108864 33554432  33554432  50% /data
'@;exit 0}
        '^dumpsys battery$' {@'
AC powered: true
level: 80
temperature: 320
'@;exit 0}
        '^dumpsys power$' {'Battery Saver is currently: OFF';exit 0}
        '^dumpsys thermalservice$' {'Thermal Status: 0';exit 0}
        '^dumpsys SurfaceFlinger --timestats -dump$' {@'
statsStart = 100
statsEnd = 102
layerName = SurfaceView[com.example.game/com.example.game.MainActivity](BLAST)#42
totalFrames = 60
averageFPS = 30.000
presentToPresentHistogram = 16: 0, 33: 55, 50: 3, 67: 1, 100: 1
'@;exit 0}
        '^cmd package resolve-activity --brief ' {'com.example.game/com.example.game.MainActivity';exit 0}
        '^command -v ' {"/system/bin/$($cmd.Split(' ')[-1])";exit 0}
        '^perfetto --help$' {'perfetto mock help';exit 0}
        '^cat /data/local/tmp/gpk_perfetto_.*\| perfetto --txt -c - -o /data/misc/perfetto-traces/gpk_.* --background$' {'5432';exit 0}
        'echo \$!$' {'4321';exit 0}
        '^dumpsys meminfo ' {'TOTAL PSS: 524288';'TOTAL RSS: 600000';exit 0}
        '^dumpsys gfxinfo ' {'Mock gfxinfo';exit 0}
        '^am start -W ' {'Status: ok';'ThisTime: 500';'TotalTime: 700';'WaitTime: 750';exit 0}
        default {'OK';exit 0}
    }
}
exit 0
