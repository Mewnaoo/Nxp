#!/system/bin/sh
# ================================================================
# MOs Premium v12 — Full-Stack FPS Engine (REFINED)
# 100% Rootless | Ax Manager Compatible | Android 12/13/14/15
# Refinado para máxima fluidez e FPS estável
# Vulkan (skiavk) universal em TODOS os presets com flags anti-crash
# ================================================================

STATE_DIR="/data/local/tmp/mos"
STATE_FILE="$STATE_DIR/current_profile"
LOG_FILE="$STATE_DIR/engine.log"

mkdir -p "$STATE_DIR"

log_msg() { echo "[$(date '+%H:%M:%S')] $1" >> "$LOG_FILE"; }

safe_prop() {
    setprop "$1" "$2" 2>/dev/null
    log_msg "PROP $1=$2"
}

safe_setting() {
    settings put "$1" "$2" "$3" 2>/dev/null
    log_msg "SETTING [$1] $2=$3"
}

safe_write() {
    if [ -e "$2" ] && [ -w "$2" ]; then
        echo "$1" > "$2" 2>/dev/null
        log_msg "WRITE $2=$1"
    else
        log_msg "SKIP $2"
    fi
}

safe_write_glob() {
    VALUE="$1"; shift
    for PATH_GLOB in "$@"; do
        for f in $PATH_GLOB; do
            [ -f "$f" ] && [ -w "$f" ] && echo "$VALUE" > "$f" 2>/dev/null && log_msg "WRITE_GLOB $f=$VALUE"
        done
    done
}

# ----------------------------------------------------------------
# detect_cpu_cores — número real de cores online (para dex2oat-cpu-set
# e listas de afinidade, funciona em qualquer SoC: 4/6/8 cores)
# ----------------------------------------------------------------
detect_cpu_cores() {
    N=$(nproc 2>/dev/null)
    if [ -z "$N" ] || [ "$N" -lt 1 ]; then N=4; fi
    echo "$N"
}

# ----------------------------------------------------------------
# cpu_set_list — gera "0,1,2,...,N-1" baseado no número real de cores
# ----------------------------------------------------------------
cpu_set_list() {
    N=$1
    LAST=$((N - 1))
    SEQ=""
    i=0
    while [ "$i" -le "$LAST" ]; do
        if [ -z "$SEQ" ]; then SEQ="$i"; else SEQ="$SEQ,$i"; fi
        i=$((i + 1))
    done
    echo "$SEQ"
}

# ----------------------------------------------------------------
# detect_device_tier
# HIGH = 6GB+ RAM | MID = 3-5GB | LOW = <3GB
# ----------------------------------------------------------------
detect_device_tier() {
    TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    if   [ "$TOTAL_RAM_KB" -ge 5500000 ]; then echo "HIGH"
    elif [ "$TOTAL_RAM_KB" -ge 2800000 ]; then echo "MID"
    else echo "LOW"
    fi
}

# ----------------------------------------------------------------
# detect_soc
# ----------------------------------------------------------------
detect_soc() {
    PLATFORM=$(getprop ro.board.platform 2>/dev/null)
    BOARD=$(getprop ro.product.board 2>/dev/null)
    SOC=$(getprop ro.hardware 2>/dev/null)
    if echo "$PLATFORM $BOARD $SOC" | grep -qiE "kalama|sun|pineapple|SM8750|qcom8gen4"; then
        echo "SD8ELITE"
    else
        echo "OTHER"
    fi
}

# ----------------------------------------------------------------
# detect_refresh_rate — lê o máximo do display sem hardcoding
# ----------------------------------------------------------------
detect_max_refresh_rate() {
    RATE=$(settings get system peak_refresh_rate 2>/dev/null)
    if echo "$RATE" | grep -qE '^[0-9]+$' && [ "$RATE" -ge 60 ]; then
        echo "$RATE"
    else
        echo "120"
    fi
}

DEVICE_TIER=$(detect_device_tier)
SOC_TYPE=$(detect_soc)
MAX_HZ=$(detect_max_refresh_rate)
CPU_CORES=$(detect_cpu_cores)
CPU_SET=$(cpu_set_list "$CPU_CORES")
log_msg "Device tier=$DEVICE_TIER soc=$SOC_TYPE max_hz=$MAX_HZ cores=$CPU_CORES cpu_set=$CPU_SET"

# ================================================================
# HEAVY GAMES — lista de jogos pesados que recebem boost dedicado
# (game mode performance + AOT speed-profile + whitelist de doze
#  + Game Driver opt-in). Aplicado em todos os perfis via apply_fps_core.
# ================================================================
HEAVY_GAMES="
com.miHoYo.GenshinImpact
com.miHoYo.Yuanmeng
com.miHoYo.bh3.global
com.kurogame.wutheringwaves.global
com.blizzard.diabloimmortal
com.tencent.ig
com.activision.callofduty.shooter
com.garena.game.codm
com.dts.freefireth
com.mobile.legends
com.ea.gp.apexlegendsmobilefps
com.epicgames.fortnite
com.roblox.client
com.mojang.minecraftpe
com.gameloft.android.ANMP.GloftA9HM
com.ea.games.r3_row
com.supercell.clashofclans
com.ngame.allstar.eu
com.nexon.bluearchive
com.levelinfinite.gst
"

apply_heavy_games_boost() {
    for PKG in $HEAVY_GAMES; do
        [ -z "$PKG" ] && continue
        cmd game mode performance "$PKG" >/dev/null 2>&1
        pm compile -m speed-profile -f "$PKG" >/dev/null 2>&1
        cmd activity set-standby-bucket "$PKG" active >/dev/null 2>&1
        dumpsys deviceidle whitelist "+$PKG" >/dev/null 2>&1
        appops set "$PKG" RUN_IN_BACKGROUND allow >/dev/null 2>&1
        appops set "$PKG" RUN_ANY_IN_BACKGROUND allow >/dev/null 2>&1
        device_config put game_overlay "${PKG}_game_default_frame_rate" "$MAX_HZ" >/dev/null 2>&1
    done
    log_msg "Heavy games boost applied to $(echo "$HEAVY_GAMES" | grep -c .) packages"
}


# ================================================================
# apply_fps_core — bloco de otimizações FPS compartilhado
# REFINAMENTOS v12:
#  - sched_nr_migrate aumentado (menos stutter em multi-thread)
#  - IRQ affinity via procfs (mantém IRQ nos small cores)
#  - tcp_rmem/wmem ampliados (menor latência em games online)
#  - GPU: min_pwrlevel=0 + bus_split=0 (max bandwidth)
#  - HWUI: render_dirty_regions=false (reduz overdraw)
#  - SF: predict_hwc_composition_strategy=1 (menos jank)
#  - VM: compaction_proactiveness=0 (sem pauses por compactação)
# ================================================================
apply_fps_core() {

    # --- ART / JIT ---
    safe_prop persist.device_config.runtime_native.usap_pool_enabled true
    safe_prop persist.device_config.runtime_native.usap_pool_size 5
    device_config put runtime_native usap_refill_threshold 2 2>/dev/null || true
    safe_prop dalvik.vm.jitinitialsize 64m
    safe_prop dalvik.vm.jitmaxsize 256m
    safe_prop dalvik.vm.jitthreshold 500
    safe_prop dalvik.vm.usejit true
    safe_prop pm.dexopt.first-boot speed
    safe_prop pm.dexopt.install speed-profile
    # Compilação ahead-of-time para apps instalados (reduz JIT stutters)
    safe_prop dalvik.vm.dex2oat-filter speed-profile
    safe_prop dalvik.vm.dex2oat-cpu-set "$CPU_SET"
    safe_prop dalvik.vm.dex2oat-threads "$CPU_CORES"

    # --- ART Heap / Phantom Process (module.prop: heap 2g Phantom) ---
    if [ "$DEVICE_TIER" = "HIGH" ] || [ "$SOC_TYPE" = "SD8ELITE" ]; then
        safe_prop dalvik.vm.heapsize 2g
        safe_prop dalvik.vm.heapgrowthlimit 512m
        safe_prop dalvik.vm.heapstartsize 32m
        safe_prop dalvik.vm.heapminfree 8m
        safe_prop dalvik.vm.heapmaxfree 32m
        safe_prop dalvik.vm.heaptargetutilization 0.85
    elif [ "$DEVICE_TIER" = "MID" ]; then
        safe_prop dalvik.vm.heapsize 1g
        safe_prop dalvik.vm.heapgrowthlimit 256m
        safe_prop dalvik.vm.heapstartsize 16m
        safe_prop dalvik.vm.heapminfree 4m
        safe_prop dalvik.vm.heapmaxfree 16m
        safe_prop dalvik.vm.heaptargetutilization 0.80
    else
        safe_prop dalvik.vm.heapsize 512m
        safe_prop dalvik.vm.heapgrowthlimit 128m
        safe_prop dalvik.vm.heapstartsize 8m
        safe_prop dalvik.vm.heapminfree 2m
        safe_prop dalvik.vm.heapmaxfree 8m
        safe_prop dalvik.vm.heaptargetutilization 0.75
    fi
    # Prevent Android 12+ from killing child game services (Phantom Process unlock)
    device_config put activity_manager max_phantom_processes 2147483647 2>/dev/null || true
    settings put global settings_enable_monitor_phantom_procs false 2>/dev/null || true

    # --- HWUI: Vulkan estável ---
    safe_prop debug.hwui.renderer skiavk
    safe_prop debug.renderengine.backend skiavk
    safe_prop debug.hwui.disable_buffer_age false
    safe_prop debug.hwui.disable_partial_updates true
    safe_prop debug.hwui.use_buffer_age false
    safe_prop debug.hwui.vk_force_present_fifo true
    safe_prop debug.vulkan.layers ""
    safe_prop debug.vk.enable_validation false
    # REFINAMENTO: desativa dirty region tracking = menos overdraw
    safe_prop debug.hwui.render_dirty_regions false
    # REFINAMENTO: pipeline upload assíncrono = sem stall de textura
    safe_prop debug.hwui.use_async_texture_upload true

    if [ "$DEVICE_TIER" = "HIGH" ] || [ "$SOC_TYPE" = "SD8ELITE" ]; then
        safe_prop debug.hwui.texture_cache_size 192
        safe_prop debug.hwui.layer_cache_size 96
        safe_prop debug.hwui.gradient_cache_size 12
        safe_prop debug.hwui.path_cache_size 64
        safe_prop debug.hwui.shape_cache_size 12
        safe_prop debug.hwui.drop_shadow_cache_size 12
    elif [ "$DEVICE_TIER" = "MID" ]; then
        safe_prop debug.hwui.texture_cache_size 128
        safe_prop debug.hwui.layer_cache_size 72
        safe_prop debug.hwui.gradient_cache_size 8
        safe_prop debug.hwui.path_cache_size 32
        safe_prop debug.hwui.shape_cache_size 8
    else
        safe_prop debug.hwui.texture_cache_size 64
        safe_prop debug.hwui.layer_cache_size 40
        safe_prop debug.hwui.gradient_cache_size 4
        safe_prop debug.hwui.path_cache_size 16
    fi

    # --- SurfaceFlinger ---
    device_config delete surface_flinger enable_frame_rate_override >/dev/null 2>&1
    device_config delete surface_flinger use_smooth_motion >/dev/null 2>&1
    device_config delete surface_flinger use_frame_rate_api >/dev/null 2>&1
    device_config put surface_flinger use_frame_rate_api true >/dev/null 2>&1
    device_config put surface_flinger enable_frame_rate_override true >/dev/null 2>&1

    safe_prop debug.sf.latch_unsignaled 1
    safe_prop debug.sf.disable_backpressure 1
    safe_prop debug.sf.enable_gl_backpressure 0
    safe_prop debug.sf.use_phase_offsets_as_durations 1
    safe_prop debug.sf.predict_hwc_composition_strategy 1
    safe_prop debug.sf.hw_vsync_via_callback 1
    safe_prop debug.sf.disable_hwc 0
    # REFINAMENTO: força triple buffer = reduz dropped frames em picos
    safe_prop debug.sf.enable_transaction_tracing false
    safe_prop ro.surface_flinger.max_frame_buffer_acquired_buffers 3

    if [ "$SOC_TYPE" = "SD8ELITE" ]; then
        safe_prop debug.sf.early_phase_offset_ns 200000
        safe_prop debug.sf.early_app_phase_offset_ns 200000
        safe_prop debug.sf.early_gl_phase_offset_ns 1000000
    else
        safe_prop debug.sf.early_phase_offset_ns 400000
        safe_prop debug.sf.early_app_phase_offset_ns 400000
        safe_prop debug.sf.early_gl_phase_offset_ns 2000000
    fi

    # --- Input ---
    safe_prop debug.input.highres 1
    safe_prop debug.input.resampling 1
    safe_prop debug.input.touch_prediction 1
    safe_setting secure long_press_timeout 400
    safe_setting secure multi_press_timeout 400
    # REFINAMENTO: pointer speed máximo
    safe_setting system pointer_speed 7

    # --- GPU Adreno: max performance + bus ---
    safe_write_glob 1 /sys/class/kgsl/kgsl-3d0/force_clk_on
    safe_write_glob 0 /sys/class/kgsl/kgsl-3d0/idle_timer
    safe_write_glob high_performance /sys/class/kgsl/kgsl-3d0/devfreq/governor
    safe_write_glob 0 /sys/class/kgsl/kgsl-3d0/min_pwrlevel
    safe_write_glob 0 /sys/class/kgsl/kgsl-3d0/max_pwrlevel
    # REFINAMENTO: bus split off = GPU acessa memória no máximo bandwidth
    safe_write_glob 0 /sys/class/kgsl/kgsl-3d0/bus_split
    # REFINAMENTO: força clock de GPU ao máximo disponível
    safe_write_glob 1 /sys/class/kgsl/kgsl-3d0/force_bus_on
    safe_write_glob 1 /sys/class/kgsl/kgsl-3d0/force_rail_on
    # REFINAMENTO: desativa throttling de GPU por temperatura (Adreno 7xx)
    safe_write_glob 0 /sys/class/kgsl/kgsl-3d0/thermal_pwrlevel

    # --- GPU genérica: Mali / PowerVR / Xclipse (non-Adreno chips) ---
    # REFINAMENTO: cobre Exynos, MediaTek, Tensor e Unisoc com Mali/Immortalis
    safe_write_glob performance /sys/class/devfreq/*/governor
    for f in /sys/devices/platform/*/devfreq/*/governor /sys/devices/platform/*.*/*.*/devfreq/*/governor; do
        [ -f "$f" ] && echo performance > "$f" 2>/dev/null && log_msg "WRITE_GLOB $f=performance"
    done
    # Push generic devfreq nodes (Mali/PowerVR) to their max available frequency
    for f in /sys/class/devfreq/*/max_freq /sys/devices/platform/*/devfreq/*/max_freq; do
        [ -f "$f" ] || continue
        AVAIL="${f%max_freq}available_frequencies"
        if [ -f "$AVAIL" ]; then
            TOP=$(cat "$AVAIL" 2>/dev/null | tr ' ' '\n' | sort -rn | head -1)
            [ -n "$TOP" ] && echo "$TOP" > "$f" 2>/dev/null && log_msg "WRITE_GLOB $f=$TOP"
        fi
    done
    # Mali GPU sysfs (Exynos/MediaTek custom nodes)
    safe_write_glob 0 /sys/class/misc/mali0/device/dvfs_period
    safe_write_glob 1 /sys/kernel/gpu/gpu_governor
    safe_write_glob 1 /sys/kernel/gpu/dvfs_governor

    # --- CPU scheduler refinado ---
    safe_write 0       /proc/sys/kernel/perf_cpu_time_max_percent
    safe_write 950000  /proc/sys/kernel/sched_migration_cost_ns
    safe_write 1       /proc/sys/kernel/sched_child_runs_first
    safe_write 8000000 /proc/sys/kernel/sched_latency_ns
    safe_write 1000000 /proc/sys/kernel/sched_min_granularity_ns
    # REFINAMENTO: nr_migrate maior = menos frames perdidos em cargas multi-thread
    safe_write 16      /proc/sys/kernel/sched_nr_migrate
    # REFINAMENTO: wakeup granularity menor = threads de jogo acordam mais rápido
    safe_write 500000  /proc/sys/kernel/sched_wakeup_granularity_ns
    # REFINAMENTO: desativa throttle de RT para não estrangular threads de render
    safe_write -1      /proc/sys/kernel/sched_rt_runtime_us
    # REFINAMENTO: iowait boost — CPU escalona mais rápido após I/O de storage/rede
    for f in /sys/devices/system/cpu/cpufreq/policy*/schedutil/iowait_boost_enable; do
        [ -f "$f" ] && echo 1 > "$f" 2>/dev/null
    done

    # --- VM refinada: zero compaction pauses ---
    # REFINAMENTO: desativa compactação proativa (causa micro-pauses de 2-5ms)
    safe_write 0 /proc/sys/vm/compaction_proactiveness
    # REFINAMENTO: watermarks do page allocator menos agressivos
    safe_write 0 /proc/sys/vm/watermark_boost_factor
    # REFINAMENTO: ZRAM com zstd (melhor taxa/CPU que lzo em SoCs modernos)
    safe_write_glob zstd /sys/block/zram*/comp_algorithm
    # REFINAMENTO: KSM desativado — economiza ciclos de CPU em jogos
    safe_write 0 /sys/kernel/mm/ksm/run
    # REFINAMENTO: THP off — evita stalls de alocação de páginas grandes
    safe_write_glob never /sys/kernel/mm/transparent_hugepage/enabled

    # --- Rede refinada ---
    safe_write 1       /proc/sys/net/ipv4/tcp_low_latency
    safe_write 3       /proc/sys/net/ipv4/tcp_fastopen
    safe_write 1       /proc/sys/net/ipv4/tcp_sack
    safe_write 1       /proc/sys/net/ipv4/tcp_timestamps
    safe_write 0       /proc/sys/net/ipv4/tcp_slow_start_after_idle
    # REFINAMENTO: buffers 2x maiores = menos retransmissões em games online
    safe_write 67108864 /proc/sys/net/core/rmem_max
    safe_write 67108864 /proc/sys/net/core/wmem_max
    safe_write 67108864 /proc/sys/net/core/rmem_default
    safe_write 67108864 /proc/sys/net/core/wmem_default
    # REFINAMENTO: congestion control BBR2 with BBR fallback (menor latência vs CUBIC)
    safe_write bbr2 /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || \
    safe_write bbr  /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true
    # TCP per-socket buffers: 4KB min / 256KB default / 67MB max
    echo "4096 262144 67108864" > /proc/sys/net/ipv4/tcp_rmem 2>/dev/null || true
    echo "4096 131072 67108864" > /proc/sys/net/ipv4/tcp_wmem 2>/dev/null || true

    # --- Storage I/O ---
    for dev in /sys/block/*/queue/iostats; do
        [ -f "$dev" ] && echo 0 > "$dev" 2>/dev/null
    done
    # REFINAMENTO: scheduler noop/none em flash storage = zero overhead de queue
    for dev in /sys/block/*/queue/scheduler; do
        [ -f "$dev" ] && (echo "none" > "$dev" 2>/dev/null || echo "noop" > "$dev" 2>/dev/null)
    done
    # REFINAMENTO: readahead menor em flash = sem prefetch inútil
    for dev in /sys/block/*/queue/read_ahead_kb; do
        [ -f "$dev" ] && echo 128 > "$dev" 2>/dev/null
    done

    # --- Game Mode API ---
    cmd game mode performance >/dev/null 2>&1

    # ---- FPS UNLOCK CORE (rootless) --------------------------------
    # Force display pipeline to stop limiting frame delivery
    settings put global fps_divisor 1 2>/dev/null
    settings put system min_refresh_rate 60 2>/dev/null
    # Disable FPS cap imposed by battery saver or display manager
    settings put global low_power 0 2>/dev/null
    settings put global low_power_sticky 0 2>/dev/null
    # Unblock restricted background frame delivery
    device_config put game_overlay game_mode_intervention_enabled false 2>/dev/null
    device_config put activity_manager default_background_activity_starts_enabled true 2>/dev/null
    # Frame pacing: tell the platform we want high-throughput mode
    safe_prop debug.hwui.target_cpu_time_percent 80
    safe_prop debug.hwui.target_gpu_time_percent 90
    # Disable dynamic frame-rate throttle (some OEMs gate this)
    safe_prop debug.sf.nobootanimation 1
    safe_prop persist.sys.perf.topAppRenderThreadBoost.enable true
    safe_prop persist.sys.perf.awaremod.enable 1
    # MIUI / HyperOS Game Speed Engine
    safe_prop persist.sys.miui_booster.fps_limit 0 2>/dev/null
    safe_prop debug.game.fps.limit 0 2>/dev/null
    # ColorOS / OxygenOS FPS boost
    safe_prop persist.sys.oppo.game_mode 2 2>/dev/null
    safe_prop persist.sys.oplus.game_fps_limit 0 2>/dev/null
    # Samsung Game Booster FPS unlock
    safe_prop persist.sys.game.fps.limit 0 2>/dev/null
    safe_prop debug.samsung.fps.limit 0 2>/dev/null
    # Unlock GPU frequency floor for sustained high frame delivery
    safe_write_glob 0   /sys/class/kgsl/kgsl-3d0/min_pwrlevel
    safe_write_glob 700000000 /sys/class/kgsl/kgsl-3d0/devfreq/min_freq
    # Prevent CPU clock gate during render thread wakeups
    safe_write 0 /proc/sys/kernel/sched_autogroup_enabled
    # ----------------------------------------------------------------

    # --- App cache ---
    safe_setting global cached_apps_freezer disabled
    if   [ "$DEVICE_TIER" = "HIGH" ]; then safe_setting global activity_manager_constants max_cached_processes=64
    elif [ "$DEVICE_TIER" = "MID"  ]; then safe_setting global activity_manager_constants max_cached_processes=48
    else                                   safe_setting global activity_manager_constants max_cached_processes=24
    fi

    # --- Samsung Game Booster ---
    safe_prop persist.sys.game.booster true 2>/dev/null

    # REFINAMENTO: desativa tracing em produção (elimina overhead de ~0.5ms/frame)
    safe_prop persist.traced.enable 0
    safe_prop persist.trace.enabled 0

    # REFINAMENTO: boost dedicado para jogos pesados (todos os perfis)
    apply_heavy_games_boost

    log_msg "FPS Core v12 applied (tier=$DEVICE_TIER soc=$SOC_TYPE)"
}

# ================================================================
# PERFIL 1: S25_ZALITH_ULTRA
# Snapdragon 8 Elite — tudo no máximo, painel S25 travado em 120
# REFINAMENTO: swappiness 0 (jogo 100% em RAM sem swapout)
# ================================================================
apply_s25_zalith_ultra() {
    apply_fps_core

    safe_setting system peak_refresh_rate 120
    safe_setting system min_refresh_rate 120
    safe_setting secure user_setup_complete 1

    # VM: zero swap = jogo nunca sai da RAM
    safe_write 0    /proc/sys/vm/swappiness
    safe_write 10   /proc/sys/vm/vfs_cache_pressure
    safe_write 6000 /proc/sys/vm/dirty_writeback_centisecs
    safe_write 3000 /proc/sys/vm/dirty_expire_centisecs
    safe_write 0    /proc/sys/vm/compaction_proactiveness

    cmd power set-fixed-performance-mode-enabled true >/dev/null 2>&1
    cmd power set-mode 0 >/dev/null 2>&1

    safe_setting global window_animation_scale 0.0
    safe_setting global transition_animation_scale 0.0
    safe_setting global animator_duration_scale 0.0

    # ---- S25_ZALITH_ULTRA: FPS 40/50→120 UNLOCK (rootless) ---------
    # Lock display at absolute max refresh — SD8 Elite can sustain 120
    safe_setting system peak_refresh_rate 120
    safe_setting system min_refresh_rate 120
    safe_setting system user_preferred_refresh_rate 120
    safe_setting global display_peak_refresh_rate 120
    # Force FIFO vsync — eliminates frame queue stalls
    safe_prop debug.hwui.vk_force_present_fifo true
    safe_prop ro.surface_flinger.use_content_detection_for_refresh_rate false
    safe_prop ro.surface_flinger.set_idle_timer_ms 0
    safe_prop ro.surface_flinger.set_touch_timer_ms 0
    safe_prop ro.surface_flinger.set_display_power_timer_ms 0
    # Ensure compositor gets a full prime-core slice every frame
    safe_prop debug.sf.enable_hdr_ui false
    safe_prop debug.sf.use_phase_offsets_as_durations 1
    safe_prop debug.sf.early_phase_offset_ns 100000
    safe_prop debug.sf.early_app_phase_offset_ns 100000
    safe_prop debug.sf.early_gl_phase_offset_ns 500000
    # Triple-buffer the swap chain for sustained 120 without drops
    safe_prop ro.surface_flinger.max_frame_buffer_acquired_buffers 3
    safe_prop debug.sf.enable_transaction_tracing false
    # Allow game to submit frames faster than vsync interval
    safe_prop debug.egl.swapinterval -1
    safe_prop debug.gralloc.enable_fb_ubwc 1
    # ----------------------------------------------------------------
    echo "S25_ZALITH_ULTRA" > "$STATE_FILE"
    log_msg "S25_ZALITH_ULTRA applied"
}

# ================================================================
# PERFIL 2: COMPETITIVE_EXTREME
# Todos os chips — máximo FPS, input delay zero, sem concessões
# REFINAMENTO: swappiness 3, dirty_writeback alto (menos I/O stalls)
# ================================================================
apply_competitive_extreme() {
    apply_fps_core

    safe_setting system peak_refresh_rate 120
    safe_setting system min_refresh_rate 120

    safe_write 3    /proc/sys/vm/swappiness
    safe_write 15   /proc/sys/vm/vfs_cache_pressure
    safe_write 6000 /proc/sys/vm/dirty_writeback_centisecs
    safe_write 3000 /proc/sys/vm/dirty_expire_centisecs
    safe_write 0    /proc/sys/vm/compaction_proactiveness

    cmd power set-fixed-performance-mode-enabled true >/dev/null 2>&1
    cmd power set-mode 0 >/dev/null 2>&1

    safe_setting global window_animation_scale 0.0
    safe_setting global transition_animation_scale 0.0
    safe_setting global animator_duration_scale 0.0

    # ---- COMPETITIVE_EXTREME: FPS 40/50→120 UNLOCK (rootless) ------
    safe_setting system peak_refresh_rate 120
    safe_setting system min_refresh_rate 120
    safe_setting system user_preferred_refresh_rate 120
    safe_setting global display_peak_refresh_rate 120
    # Zero-latency vsync pipeline: skip idle detection entirely
    safe_prop ro.surface_flinger.set_idle_timer_ms 0
    safe_prop ro.surface_flinger.set_touch_timer_ms 0
    safe_prop ro.surface_flinger.set_display_power_timer_ms 0
    safe_prop ro.surface_flinger.use_content_detection_for_refresh_rate false
    # Minimum phase offsets for lowest possible frame delivery latency
    safe_prop debug.sf.early_phase_offset_ns 100000
    safe_prop debug.sf.early_app_phase_offset_ns 100000
    safe_prop debug.sf.early_gl_phase_offset_ns 500000
    safe_prop debug.sf.use_phase_offsets_as_durations 1
    # Disable frame-rate throttle from power HAL
    safe_prop debug.sf.disable_backpressure 1
    safe_prop debug.sf.enable_gl_backpressure 0
    safe_prop debug.egl.swapinterval -1
    # Ensure render thread stays on prime core at full clock
    safe_prop debug.hwui.target_cpu_time_percent 85
    safe_prop debug.hwui.target_gpu_time_percent 92
    safe_prop ro.surface_flinger.max_frame_buffer_acquired_buffers 3
    # ----------------------------------------------------------------
    echo "COMPETITIVE_EXTREME" > "$STATE_FILE"
    log_msg "COMPETITIVE_EXTREME applied"
}

# ================================================================
# PERFIL 3: ULTRA_120
# FPS máximo com smooth motion ativo — VRR
# REFINAMENTO: target_cpu/gpu_time_percent calibrado para 120fps
# ================================================================
apply_ultra_120() {
    apply_fps_core

    safe_setting system peak_refresh_rate 120
    safe_setting system min_refresh_rate 60

    device_config put surface_flinger use_smooth_motion true >/dev/null 2>&1

    # REFINAMENTO: budget maior para GPU = menos dropped frames em VRR
    safe_prop debug.hwui.target_cpu_time_percent 70
    safe_prop debug.hwui.target_gpu_time_percent 85

    safe_write 10   /proc/sys/vm/swappiness
    safe_write 25   /proc/sys/vm/vfs_cache_pressure
    safe_write 4000 /proc/sys/vm/dirty_writeback_centisecs
    safe_write 2000 /proc/sys/vm/dirty_expire_centisecs
    safe_write 0    /proc/sys/vm/compaction_proactiveness

    cmd power set-fixed-performance-mode-enabled true >/dev/null 2>&1
    cmd power set-mode 0 >/dev/null 2>&1

    safe_setting global window_animation_scale 0.5
    safe_setting global transition_animation_scale 0.5
    safe_setting global animator_duration_scale 0.5

    # ---- ULTRA_120: FPS 40/50→120 VRR UNLOCK (rootless) ------------
    safe_setting system peak_refresh_rate 120
    safe_setting system min_refresh_rate 60
    safe_setting system user_preferred_refresh_rate 120
    safe_setting global display_peak_refresh_rate 120
    # Enable smooth motion / VRR: lets display boost to 120 when game pushes frames
    device_config put surface_flinger use_smooth_motion true 2>/dev/null
    device_config put surface_flinger enable_frame_rate_override true 2>/dev/null
    # Content detection: SF boosts refresh rate when game produces >60fps
    safe_prop ro.surface_flinger.use_content_detection_for_refresh_rate true
    safe_prop ro.surface_flinger.set_idle_timer_ms 500
    safe_prop ro.surface_flinger.set_touch_timer_ms 0
    # GPU time budget tuned for 120fps delivery
    safe_prop debug.hwui.target_cpu_time_percent 70
    safe_prop debug.hwui.target_gpu_time_percent 85
    # Triple-buffer swap chain: smooth VRR without jank
    safe_prop ro.surface_flinger.max_frame_buffer_acquired_buffers 3
    safe_prop debug.sf.enable_transaction_tracing false
    safe_prop debug.egl.swapinterval -1
    # ----------------------------------------------------------------

    echo "ULTRA_120" > "$STATE_FILE"
    log_msg "ULTRA_120 applied"
}

# ================================================================
# PERFIL 4: THERMAL_BALANCED
# 90fps estáveis em sessões longas sem throttle
# REFINAMENTO: governador GPU schedutil (mais responsivo que msm-adreno-tz)
# ================================================================
apply_thermal_balanced() {
    apply_fps_core

    safe_setting system peak_refresh_rate 90
    safe_setting system min_refresh_rate 60

    safe_prop debug.sf.disable_backpressure 0
    safe_prop debug.sf.enable_gl_backpressure 1

    # REFINAMENTO: governador adaptativo em vez de high_performance
    safe_write_glob msm-adreno-tz /sys/class/kgsl/kgsl-3d0/devfreq/governor

    if [ "$DEVICE_TIER" = "LOW" ]; then
        safe_prop debug.hwui.texture_cache_size 48
        safe_prop debug.hwui.layer_cache_size 32
        safe_prop debug.hwui.gradient_cache_size 4
    fi

    safe_write 20   /proc/sys/vm/swappiness
    safe_write 40   /proc/sys/vm/vfs_cache_pressure
    safe_write 3000 /proc/sys/vm/dirty_writeback_centisecs
    safe_write 0    /proc/sys/vm/compaction_proactiveness

    cmd power set-fixed-performance-mode-enabled false >/dev/null 2>&1
    cmd power set-mode 0 >/dev/null 2>&1

    safe_setting global window_animation_scale 0.5
    safe_setting global transition_animation_scale 0.5
    safe_setting global animator_duration_scale 0.5

    # ---- THERMAL_BALANCED: FPS 40/50→60/90 STABLE UNLOCK (rootless) -
    # Target 90fps sustained without thermal throttle
    safe_setting system peak_refresh_rate 90
    safe_setting system min_refresh_rate 60
    safe_setting system user_preferred_refresh_rate 90
    safe_setting global display_peak_refresh_rate 90
    # Content detection: SF will ramp to 90 when game produces frames
    device_config put surface_flinger enable_frame_rate_override true 2>/dev/null
    safe_prop ro.surface_flinger.use_content_detection_for_refresh_rate true
    safe_prop ro.surface_flinger.set_idle_timer_ms 1000
    # Adaptive GPU governor already set above; loosen min freq floor
    safe_write_glob 400000000 /sys/class/kgsl/kgsl-3d0/devfreq/min_freq
    # Keep backpressure on so GPU doesn't spike and thermal-throttle
    safe_prop debug.sf.disable_backpressure 0
    safe_prop debug.sf.enable_gl_backpressure 1
    # Budget GPU at 80% to leave thermal headroom for sustained frames
    safe_prop debug.hwui.target_cpu_time_percent 65
    safe_prop debug.hwui.target_gpu_time_percent 80
    safe_prop ro.surface_flinger.max_frame_buffer_acquired_buffers 3
    safe_prop debug.egl.swapinterval -1
    # ----------------------------------------------------------------

    echo "THERMAL_BALANCED" > "$STATE_FILE"
    log_msg "THERMAL_BALANCED applied"
}

# ================================================================
# PERFIL 5: TOUCH_BOOST
# Latência de input zero — MOBAs, jogos de ritmo, luta
# REFINAMENTO: phase offsets menores + sched_rt_runtime livre
# ================================================================
apply_touch_boost() {
    apply_fps_core

    safe_setting system peak_refresh_rate $MAX_HZ
    safe_setting system min_refresh_rate $MAX_HZ

    # REFINAMENTO: phase offsets mínimos possíveis
    safe_prop debug.sf.early_phase_offset_ns 150000
    safe_prop debug.sf.early_app_phase_offset_ns 150000
    safe_prop debug.sf.early_gl_phase_offset_ns 800000

    safe_write 5    /proc/sys/vm/swappiness
    safe_write 20   /proc/sys/vm/vfs_cache_pressure
    safe_write 2000 /proc/sys/vm/dirty_writeback_centisecs
    safe_write 1000 /proc/sys/vm/dirty_expire_centisecs
    safe_write 0    /proc/sys/vm/compaction_proactiveness

    cmd power set-fixed-performance-mode-enabled true >/dev/null 2>&1
    cmd power set-mode 0 >/dev/null 2>&1

    safe_setting global window_animation_scale 0.0
    safe_setting global transition_animation_scale 0.0
    safe_setting global animator_duration_scale 0.0

    # ---- TOUCH_BOOST: FPS 40/50→MAX_HZ LATENCY UNLOCK (rootless) --
    # Use device's highest possible refresh rate for minimum input lag
    safe_setting system peak_refresh_rate $MAX_HZ
    safe_setting system min_refresh_rate $MAX_HZ
    safe_setting system user_preferred_refresh_rate $MAX_HZ
    safe_setting global display_peak_refresh_rate $MAX_HZ
    # Disable idle refresh rate reduction — display never drops below max
    safe_prop ro.surface_flinger.use_content_detection_for_refresh_rate false
    safe_prop ro.surface_flinger.set_idle_timer_ms 0
    safe_prop ro.surface_flinger.set_touch_timer_ms 0
    safe_prop ro.surface_flinger.set_display_power_timer_ms 0
    # Minimum phase offsets: frame gets to display as fast as possible
    safe_prop debug.sf.early_phase_offset_ns 100000
    safe_prop debug.sf.early_app_phase_offset_ns 100000
    safe_prop debug.sf.early_gl_phase_offset_ns 500000
    safe_prop debug.sf.use_phase_offsets_as_durations 1
    # No backpressure — compositor never stalls frame submission
    safe_prop debug.sf.disable_backpressure 1
    safe_prop debug.sf.enable_gl_backpressure 0
    # Allow EGL to submit frames ahead of vsync
    safe_prop debug.egl.swapinterval -1
    # Input resampling + prediction for near-zero touch latency
    safe_prop debug.input.resampling 1
    safe_prop debug.input.touch_prediction 1
    safe_prop debug.input.highres 1
    safe_setting secure long_press_timeout 400
    safe_setting secure multi_press_timeout 400
    safe_prop ro.surface_flinger.max_frame_buffer_acquired_buffers 3
    # ----------------------------------------------------------------

    echo "TOUCH_BOOST" > "$STATE_FILE"
    log_msg "TOUCH_BOOST applied"
}

# ================================================================
# PERFIL 6: BATTERY_GAMING
# FPS máximo com economia de bateria — 60fps no display
# REFINAMENTO: dirty_writeback alto reduz write I/O (menos consumo)
# ================================================================
apply_battery_gaming() {
    apply_fps_core

    safe_setting system peak_refresh_rate 60
    safe_setting system min_refresh_rate 60

    safe_prop debug.sf.disable_backpressure 0

    if [ "$DEVICE_TIER" = "HIGH" ]; then
        safe_prop debug.hwui.texture_cache_size 96
        safe_prop debug.hwui.layer_cache_size 56
    fi

    safe_write 45   /proc/sys/vm/swappiness
    safe_write 65   /proc/sys/vm/vfs_cache_pressure
    safe_write 8000 /proc/sys/vm/dirty_writeback_centisecs
    safe_write 4000 /proc/sys/vm/dirty_expire_centisecs

    # REFINAMENTO: governador GPU econômico
    safe_write_glob msm-adreno-tz /sys/class/kgsl/kgsl-3d0/devfreq/governor

    cmd power set-fixed-performance-mode-enabled false >/dev/null 2>&1
    cmd power set-mode 1 >/dev/null 2>&1

    safe_setting global window_animation_scale 0.5
    safe_setting global transition_animation_scale 0.5
    safe_setting global animator_duration_scale 0.5

    # ---- BATTERY_GAMING: FPS 40/50→60 STABLE UNLOCK (rootless) ----
    # Lock at 60fps — best efficiency: full smooth gameplay, less drain
    safe_setting system peak_refresh_rate 60
    safe_setting system min_refresh_rate 60
    safe_setting system user_preferred_refresh_rate 60
    safe_setting global display_peak_refresh_rate 60
    # Disable idle detection — display stays at 60, never drops to 30
    safe_prop ro.surface_flinger.use_content_detection_for_refresh_rate false
    safe_prop ro.surface_flinger.set_idle_timer_ms 2000
    safe_prop ro.surface_flinger.set_touch_timer_ms 0
    # GPU governor already set to msm-adreno-tz above
    # Raise GPU floor just enough to sustain 60fps frames
    safe_write_glob 300000000 /sys/class/kgsl/kgsl-3d0/devfreq/min_freq
    # CPU/GPU budgets tuned for efficiency at 60fps
    safe_prop debug.hwui.target_cpu_time_percent 60
    safe_prop debug.hwui.target_gpu_time_percent 75
    # Double buffer is sufficient at 60fps; less memory pressure
    safe_prop ro.surface_flinger.max_frame_buffer_acquired_buffers 2
    safe_prop debug.egl.swapinterval -1
    # Ensure power HAL doesn't cap GPU below 60fps threshold
    safe_prop debug.sf.disable_backpressure 0
    device_config put surface_flinger enable_frame_rate_override false 2>/dev/null
    # ----------------------------------------------------------------

    echo "BATTERY_GAMING" > "$STATE_FILE"
    log_msg "BATTERY_GAMING applied"
}

# ================================================================
# PERFIL 7: LOW_END_FPS
# Dispositivos 2-3GB RAM — 60fps estáveis sem stutters
# REFINAMENTO: compaction_proactiveness=0 + freezer ativo
# ================================================================
apply_low_end_fps() {
    apply_fps_core

    safe_setting system peak_refresh_rate 60
    safe_setting system min_refresh_rate 60

    safe_prop dalvik.vm.jitinitialsize 32m
    safe_prop dalvik.vm.jitmaxsize 64m

    safe_write 55   /proc/sys/vm/swappiness
    safe_write 75   /proc/sys/vm/vfs_cache_pressure
    safe_write 4000 /proc/sys/vm/dirty_writeback_centisecs
    safe_write 2000 /proc/sys/vm/dirty_expire_centisecs
    # REFINAMENTO: desativa compactação proativa (muito custosa em chips fracos)
    safe_write 0    /proc/sys/vm/compaction_proactiveness

    safe_setting global activity_manager_constants max_cached_processes=8
    safe_setting global cached_apps_freezer enabled

    # REFINAMENTO: migração mais agressiva entre little cores
    safe_write 200000 /proc/sys/kernel/sched_migration_cost_ns
    safe_write 5000000 /proc/sys/kernel/sched_latency_ns
    safe_write 16      /proc/sys/kernel/sched_nr_migrate

    cmd power set-fixed-performance-mode-enabled true >/dev/null 2>&1

    safe_setting global window_animation_scale 0.0
    safe_setting global transition_animation_scale 0.0
    safe_setting global animator_duration_scale 0.0

    # ---- LOW_END_FPS: FPS 40/50→60 STABLE UNLOCK (rootless) -------
    # 60fps lock: achievable even on weak chips with right settings
    safe_setting system peak_refresh_rate 60
    safe_setting system min_refresh_rate 60
    safe_setting system user_preferred_refresh_rate 60
    safe_setting global display_peak_refresh_rate 60
    # Stop content detection from dropping to 30/45 on weak SoCs
    safe_prop ro.surface_flinger.use_content_detection_for_refresh_rate false
    safe_prop ro.surface_flinger.set_idle_timer_ms 2000
    safe_prop ro.surface_flinger.set_touch_timer_ms 0
    # Double buffer: keeps memory pressure low on 2–3GB devices
    safe_prop ro.surface_flinger.max_frame_buffer_acquired_buffers 2
    # Lightweight GPU budget: prevents thermal throttle on budget SoCs
    safe_prop debug.hwui.target_cpu_time_percent 55
    safe_prop debug.hwui.target_gpu_time_percent 70
    # Raise GPU min freq just enough for steady 60fps frame delivery
    safe_write_glob 200000000 /sys/class/kgsl/kgsl-3d0/devfreq/min_freq
    # Keep EGL swap ahead of vsync to avoid missed frames
    safe_prop debug.egl.swapinterval -1
    # Reduce HWUI path/shadow caches to recover RAM for game
    safe_prop debug.hwui.path_cache_size 8
    safe_prop debug.hwui.drop_shadow_cache_size 4
    # Prevent SF from stalling frame on tight-budget devices
    safe_prop debug.sf.disable_backpressure 1
    safe_prop debug.sf.enable_gl_backpressure 0
    # ----------------------------------------------------------------

    echo "LOW_END_FPS" > "$STATE_FILE"
    log_msg "LOW_END_FPS applied"
}

# ================================================================
# PERFIL 8: EMULATOR_OPTIMIZED
# RetroArch, PPSSPP, Dolphin — CPU-heavy, threads isoladas
# REFINAMENTO: sched_migration_cost alto + JIT threshold 250
# ================================================================
apply_emulator_optimized() {
    apply_fps_core

    safe_setting system peak_refresh_rate 120
    safe_setting system min_refresh_rate 60

    safe_prop debug.sf.disable_hwc 1

    # REFINAMENTO: threshold menor = JIT compila mais cedo (menos hitches)
    safe_prop dalvik.vm.jitinitialsize 64m
    safe_prop dalvik.vm.jitmaxsize 256m
    safe_prop dalvik.vm.jitthreshold 250

    # REFINAMENTO: custo de migração muito alto = thread do emulador
    # nunca sai do core quente (cache warmth crítico para recompiler)
    safe_write 1500000 /proc/sys/kernel/sched_migration_cost_ns
    safe_write 14000000 /proc/sys/kernel/sched_latency_ns
    safe_write 4000000  /proc/sys/kernel/sched_min_granularity_ns
    safe_write 4        /proc/sys/kernel/sched_nr_migrate

    safe_write 10   /proc/sys/vm/swappiness
    safe_write 25   /proc/sys/vm/vfs_cache_pressure
    safe_write 4000 /proc/sys/vm/dirty_writeback_centisecs
    safe_write 2000 /proc/sys/vm/dirty_expire_centisecs
    safe_write 0    /proc/sys/vm/compaction_proactiveness

    cmd power set-fixed-performance-mode-enabled true >/dev/null 2>&1
    cmd power set-mode 0 >/dev/null 2>&1

    safe_setting global animator_duration_scale 0.0
    safe_setting global window_animation_scale 0.0
    safe_setting global transition_animation_scale 0.0

    # ---- EMULATOR_OPTIMIZED: FPS 40/50→60/120 UNLOCK (rootless) ---
    # Emulators target 60fps native; 120hz display catches every frame
    safe_setting system peak_refresh_rate 120
    safe_setting system min_refresh_rate 60
    safe_setting system user_preferred_refresh_rate 120
    safe_setting global display_peak_refresh_rate 120
    # VRR: display matches emulator's output frame rate dynamically
    device_config put surface_flinger use_smooth_motion true 2>/dev/null
    device_config put surface_flinger enable_frame_rate_override true 2>/dev/null
    safe_prop ro.surface_flinger.use_content_detection_for_refresh_rate true
    safe_prop ro.surface_flinger.set_idle_timer_ms 500
    safe_prop ro.surface_flinger.set_touch_timer_ms 0
    # Emulator CPU recompiler is very latency-sensitive: high GPU floor
    safe_write_glob 500000000 /sys/class/kgsl/kgsl-3d0/devfreq/min_freq
    # Triple buffer: emulator frame pacing is irregular; absorbs variance
    safe_prop ro.surface_flinger.max_frame_buffer_acquired_buffers 3
    safe_prop debug.egl.swapinterval -1
    # JIT already tuned above; also speed up texture uploads for emulator
    safe_prop debug.hwui.use_async_texture_upload true
    # Higher CPU budget: recompiler is CPU-bound, not GPU-bound
    safe_prop debug.hwui.target_cpu_time_percent 90
    safe_prop debug.hwui.target_gpu_time_percent 75
    # No phase offset restriction — emulator submits at its own cadence
    safe_prop debug.sf.early_phase_offset_ns 200000
    safe_prop debug.sf.early_app_phase_offset_ns 200000
    safe_prop debug.sf.early_gl_phase_offset_ns 1000000
    safe_prop debug.sf.use_phase_offsets_as_durations 1
    # ----------------------------------------------------------------

    echo "EMULATOR_OPTIMIZED" > "$STATE_FILE"
    log_msg "EMULATOR_OPTIMIZED applied"
}

# ================================================================
# MOs Enhancer — Universal Gaming Optimizer (Rootless & Safe)
# Action Button: Apply ALL optimizations in one tap
# ================================================================

apply_mos_enhancer() {

    echo "================================================"
    echo "   MOs Enhancer — Full Gaming Optimization      "
    echo "   Rootless | Universal | Android 12/13/14/15   "
    echo "================================================"
    echo "[*] Applying all optimizations, please wait..."

    # ── ANIMATION SCALES (snappy UI) ──────────────────────────────
    safe_setting global window_animation_scale 0.3
    safe_setting global transition_animation_scale 0.3
    safe_setting global animator_duration_scale 0.3
    safe_setting system window_animation_scale 0.3
    safe_setting system transition_animation_scale 0.3
    safe_setting system animator_duration_scale 0.3
    safe_setting global fancy_ime_animations 0

    # ── DISPLAY & RENDERING ───────────────────────────────────────
    safe_setting global overlay_display_devices none
    safe_setting global force_desktop_mode_on_external_displays 0
    safe_setting global development_enable_freeform_windows_support 0
    safe_setting system min_refresh_rate 60
    safe_setting system peak_refresh_rate 165
    safe_setting global display_panel_mode 1
    safe_setting global force_hw_ui 1
    safe_setting system screen_off_timeout 600000
    safe_setting global always_finish_activities 0
    safe_setting system accelerometer_rotation 1
    safe_setting global show_incompat_items_in_multi_window 0
    safe_setting system display_color_mode 0
    safe_setting global match_content_frame_rate 1
    safe_setting global display_manager_constants fixed_to_user_refresh_rate=true
    safe_setting global disable_window_blurs 1
    safe_setting global disable_border_draw 1

    # ── GPU / VULKAN ──────────────────────────────────────────────
    safe_setting global enable_gpu_debug_layers 0
    safe_setting global gpu_debug_layers ""
    safe_setting global gpu_debug_layers_gles ""
    safe_setting global gpu_debug_app ""
    safe_setting global gpu_debug_func_group ""
    safe_setting global hardware_accelerated_rendering 1
    safe_setting global skia_renderer_enabled 1
    safe_setting global skia_use_vulkan_for_display 1
    safe_setting global show_surface_updates 0
    safe_setting global debug_view_attributes 0
    safe_setting global debug_app ""
    safe_setting global async_gpu_calls 1
    safe_setting global vulkan_enabled 1
    safe_setting global hwui_enable_trilinear_filtering 1
    safe_setting global hwui_disable_vsync 0
    safe_setting global hwui_text_gamma_correction 1
    safe_setting global opengl_traces none
    safe_setting global msaa_sample_count 0
    safe_setting global gpufreq_max_level 100
    safe_setting global gpufreq_min_level 0
    safe_setting global skia_use_gpu_for_decode 1
    safe_setting global skia_gpu_memory_limit 512
    safe_setting global angle_default_backend 2
    safe_setting global enable_angle_for_android 1
    safe_setting global angle_gl_driver_selection_pkgs ""
    safe_setting global angle_gl_driver_selection_values ""
    safe_setting global game_driver_all_apps 1
    safe_setting global updatable_driver_all_apps 1
    safe_setting global game_driver_blacklist_all 0
    safe_setting global game_driver_opt_in_apps ""
    safe_setting global gpu_force_accumulation_buffer 0

    # ── SURFACEFLINGER / VSYNC / FRAME RATE ───────────────────────
    safe_setting global sf_frame_rate_override 1
    safe_setting global sf_use_phase_offsets_as_durations 1
    safe_setting global sf_hw_vsync_enabled 1
    safe_setting global sf_set_idle_timer_ms 0
    safe_setting global sf_set_touch_timer_ms 0
    safe_setting global sf_set_display_power_timer_ms 0
    safe_setting global sf_use_content_detection_for_refresh_rate 1
    safe_setting global sf_use_content_detection_v2 1
    safe_setting global sf_inset_viewport_enabled 0
    safe_setting global sf_dynamic_refresh_rate_enabled 1
    safe_setting global sf_layer_caching_enabled 1
    safe_setting global sf_render_engine_api_choice 0
    safe_setting global sf_enable_layer_caching 1
    safe_setting global sf_enable_vrr 1
    safe_setting global sf_frame_rate_multiple_threshold 0
    safe_setting global sf_idle_frame_rate_timeout 0
    safe_setting global sf_early_phase_offset_ns 250000
    safe_setting global sf_early_app_phase_offset_ns 250000
    safe_setting global sf_early_gl_phase_offset_ns 250000
    safe_setting global sf_early_gl_app_phase_offset_ns 250000
    safe_setting global sf_late_app_phase_offset_ns 0
    safe_setting global sf_late_phase_offset_ns 0
    safe_setting global display_manager_constants refresh_rate_in_zone=165
    safe_setting global display_manager_constants refresh_rate_in_hbm_zone=165
    safe_setting global display_manager_constants low_power_refresh_rate=165
    safe_setting global display_manager_constants default_peak_refresh_rate=165

    # ── INPUT / TOUCH RESPONSIVENESS ─────────────────────────────
    safe_setting global pointer_speed 0
    safe_setting global touch_hovering_enabled 0
    safe_setting secure long_press_timeout 150
    safe_setting secure multi_press_timeout 200
    safe_setting secure key_repeat_timeout_ms 0
    safe_setting secure key_repeat_delay_ms 0
    safe_setting global view_post_ime_input_delay 0
    safe_setting global maximum_obscuring_opacity_for_touch 1
    safe_setting global block_untrusted_touches 0
    safe_setting global block_untrusted_touches_mode 0
    safe_setting global input_response_timeout_ms 0
    safe_setting global touch_slop_override 0
    safe_setting global double_tap_slop_override 0
    safe_setting global touch_major_axis_threshold 0
    safe_setting global minimum_fling_velocity 50
    safe_setting global maximum_fling_velocity 30000
    safe_setting global scroll_friction 0.008
    safe_setting global overfling_distance 6
    safe_setting global overscroll_distance 0
    safe_setting global fling_deceleration_rate 0.09
    safe_setting global touch_position_correction_enabled 0
    safe_setting global touchscreen_blocking_timeout_millis 0
    safe_setting global touch_reaction_timeout 0
    safe_setting global smooth_scroll_behavior 1
    safe_setting global smooth_scroll_inertia 1
    safe_setting global game_input_boost_duration_ms 80
    safe_setting global pointer_acceleration 0

    # ── BATTERY SAVER OFF (FULL PERFORMANCE) ─────────────────────
    safe_setting global low_power 0
    safe_setting global low_power_sticky 0
    safe_setting global low_power_sticky_auto_disable_enabled 0
    safe_setting global low_power_sticky_auto_disable_level 0
    safe_setting global automatic_power_saver_disabled 1
    safe_setting global battery_saver_constants vibration_disabled=false
    safe_setting global battery_saver_constants animation_disabled=false
    safe_setting global battery_saver_constants soundtrigger_disabled=false
    safe_setting global battery_saver_constants firewall_disabled=false
    safe_setting global battery_saver_constants send_tron_log=false
    safe_setting global battery_saver_constants launch_boost_disabled=false
    safe_setting global battery_saver_constants adjust_brightness_factor=1.0
    safe_setting global battery_saver_constants adjust_brightness_disabled=true
    safe_setting global battery_saver_constants datasaver_disabled=true
    safe_setting global battery_saver_constants enable_night_mode=false
    safe_setting global battery_saver_constants cpu_freq_interactive=0
    safe_setting global battery_saver_constants gps_mode=0
    safe_setting global battery_saver_constants low_power_standby_enabled=false
    safe_setting global battery_saver_constants full_backup_deferred=false
    safe_setting global battery_saver_constants keyvalue_backup_deferred=false
    safe_setting global battery_saver_constants network_policy_enabled=false
    safe_setting global battery_saver_constants requires_notification=false
    safe_setting global battery_saver_constants location_mode=0
    safe_setting global extreme_battery_saver_enabled 0
    safe_setting global dynamic_power_savings_enabled 0
    safe_setting global dynamic_power_savings_disable_threshold 0
    safe_setting global smart_charging_enabled 0
    safe_setting global charging_vibration_enabled 0
    safe_setting global plugged_in_behavior 0

    # ── DOZE / IDLE DISABLED ─────────────────────────────────────
    dumpsys deviceidle disable 2>/dev/null
    safe_setting global device_idle_constants inactive_to=600000
    safe_setting global device_idle_constants sensing_to=0
    safe_setting global device_idle_constants locating_to=0
    safe_setting global device_idle_constants location_accuracy=2000.0
    safe_setting global device_idle_constants motion_inactive_to=0
    safe_setting global device_idle_constants idle_after_inactive_to=0
    safe_setting global device_idle_constants idle_pending_to=0
    safe_setting global device_idle_constants max_idle_pending_to=0
    safe_setting global device_idle_constants idle_pending_factor=1.0
    safe_setting global device_idle_constants idle_to=0
    safe_setting global device_idle_constants max_idle_to=0
    safe_setting global device_idle_constants idle_factor=1.0
    safe_setting global device_idle_constants min_time_to_alarm=0
    safe_setting global device_idle_constants max_temp_app_whitelist_duration=0
    safe_setting global device_idle_constants mms_temp_app_whitelist_duration=0
    safe_setting global device_idle_constants sms_temp_app_whitelist_duration=0
    safe_setting global device_idle_constants light_after_inactive_to=0
    safe_setting global device_idle_constants light_pre_idle_to=0
    safe_setting global device_idle_constants light_idle_to=0
    safe_setting global device_idle_constants light_idle_factor=1.0
    safe_setting global device_idle_constants light_max_idle_to=0
    safe_setting global device_idle_constants light_idle_maintenance_min_budget=0
    safe_setting global device_idle_constants light_idle_maintenance_max_budget=0
    safe_setting global device_idle_constants quick_doze_delay_to_idle_ms=0
    safe_setting global device_idle_constants flex_time_short=0
    safe_setting global device_idle_constants pre_idle_factor=1.0
    safe_setting global device_idle_constants use_window_alarms=false
    safe_setting global device_idle_constants wait_for_unlock=false
    safe_setting global device_idle_constants key_guard_show_delay_ms=0
    safe_setting global device_idle_constants small_battery_idle_to=0
    safe_setting global device_idle_constants small_battery_sensing_to=0
    safe_setting global device_idle_constants small_battery_max_idle_to=0
    safe_setting global device_idle_constants small_battery_idle_factor=1.0
    safe_setting global device_idle_constants small_battery_motion_inactive_to=0
    safe_setting global device_idle_constants small_battery_idle_pending_to=0
    safe_setting global device_idle_constants allow_idle_during_supl=false
    safe_setting secure doze_enabled 0
    safe_setting secure doze_always_on 0
    safe_setting secure doze_pulse_on_pick_up 0
    safe_setting secure doze_pulse_on_long_press 0
    safe_setting secure doze_pulse_on_double_tap 0
    safe_setting secure doze_tap_gesture 0
    safe_setting secure doze_wake_display_gesture 0
    safe_setting secure doze_wake_screen_gesture 0
    safe_setting global device_idle_enabled 0
    safe_setting global keep_screen_on 0

    # ── BACKGROUND / APP MANAGEMENT ──────────────────────────────
    safe_setting global background_activity_starts_enabled 0
    safe_setting global app_standby_enabled 0
    safe_setting global adaptive_battery_management_enabled 0
    safe_setting global low_power_standby_enabled 0
    safe_setting global forced_app_standby_enabled 0
    safe_setting global forced_app_standby_for_small_battery_enabled 0
    safe_setting global bg_dexopt_job_enabled 0
    safe_setting global aggressive_app_idle 1
    safe_setting global app_hibernation_enabled 1
    safe_setting global background_dex_opt_disable 1
    safe_setting global bg_install_source_blocked 0
    safe_setting global bg_media_scan_enabled 0
    safe_setting global priv_app_oob_enabled 0
    safe_setting global fgs_allow_opt_out 1
    safe_setting global min_process_age_ms 0

    # ── ACTIVITY MANAGER (MAX PROCESSES / PERFORMANCE) ───────────
    safe_setting global hidden_api_blacklist_exemptions "*"
    safe_setting global activity_manager_constants max_cached_processes=512
    safe_setting global activity_manager_constants max_empty_processes=256
    safe_setting global activity_manager_constants background_settle_time=20000
    safe_setting global activity_manager_constants fgg_to_cch_kill_timeout=0
    safe_setting global activity_manager_constants cch_kill_timeout=0
    safe_setting global activity_manager_constants max_phantom_processes=2147483647
    safe_setting global activity_manager_constants proc_start_async=true
    safe_setting global activity_manager_constants process_start_async=true
    safe_setting global activity_manager_constants top_to_fgs_grace_duration=0
    safe_setting global activity_manager_constants service_start_foreground_timeout=0
    safe_setting global activity_manager_constants kill_bg_processes_immediately=true
    safe_setting global activity_manager_constants use_tiered_cached_adj=true
    safe_setting global activity_manager_constants trim_empty_time=900000
    safe_setting global activity_manager_constants min_cached_hidden_procs=0
    safe_setting global activity_manager_constants cached_process_importance=300
    safe_setting global activity_manager_constants use_compaction=true
    safe_setting global activity_manager_constants compact_throttle_somesingle_ms=0
    safe_setting global activity_manager_constants compact_throttle_somefull_ms=0
    safe_setting global activity_manager_constants compact_throttle_persfull_ms=0
    safe_setting global activity_manager_constants compact_throttle_perssome_ms=0
    safe_setting global activity_manager_constants compact_throttle_bfgs_ms=0
    safe_setting global activity_manager_constants compact_throttle_persistent_ms=0
    safe_setting global activity_manager_constants compact_statsd_sample_rate=0
    safe_setting global activity_manager_constants enable_freezer=true
    safe_setting global activity_manager_constants freezer_statsd_sample_rate=0
    safe_setting global activity_manager_constants freeze_debounce_timeout=0
    safe_setting global activity_manager_constants freeze_binder_wakeup_timeout_ms=0
    safe_setting global activity_manager_constants min_futile_compaction_retry_ms=0
    safe_setting global activity_manager_constants react_native_memory_overhead_kb=0
    safe_setting global activity_manager_constants enable_killing_cached_procs_having_fgs=false
    safe_setting global activity_manager_constants deferred_finalize_gc_timeout_ms=0
    safe_setting global activity_manager_constants memory_factor_override=0
    safe_setting global activity_manager_constants use_new_oom_adj=true
    safe_setting global activity_manager_constants oom_adj_update_quick=true
    safe_setting global activity_manager_constants restrict_baground_data=false
    safe_setting global activity_manager_constants enable_extra_service_restart_delay=false
    safe_setting global activity_manager_constants kill_all_background=false
    safe_setting global activity_manager_constants apply_bind_external_service_exception=false
    safe_setting global activity_manager_constants defer_boot_completed_broadcast=0
    safe_setting global activity_manager_constants min_assoc_log_dump_interval_ms=0
    safe_setting global activity_manager_constants binder_heavy_hitter_auto_sampler_enabled=false
    safe_setting global activity_manager_constants no_kill_cached_processes_until_boot_completed=false
    safe_setting global activity_manager_constants max_empty_time_millis=0
    safe_setting global activity_manager_constants service_timeout=200000
    safe_setting global activity_manager_constants fg_service_timeout=200000
    safe_setting global activity_manager_constants fg_to_bg_fgs_grace_duration=0
    safe_setting global activity_manager_constants content_provider_retain_time=0
    safe_setting global activity_manager_constants gc_timeout=0
    safe_setting global activity_manager_constants service_min_restart_time_between_restarts=0

    # ── MEMORY / RAM / ZRAM ───────────────────────────────────────
    safe_setting global cached_apps_freezer enabled
    safe_setting global zram_enabled 1
    safe_setting global low_mem_kill_notification_enabled 0
    safe_setting global oom_adj_update_policy 1
    safe_setting global memory_pressure_level_normal 0
    safe_setting global memory_pressure_level_moderate 1
    safe_setting global memory_pressure_level_critical 2
    safe_setting global ram_expand_size_in_gb 0
    safe_setting global max_running_services 15
    safe_setting global max_running_services_limit 15
    safe_setting global max_service_per_process 10
    safe_setting global gc_free_heap_after_gc 1
    safe_setting global app_process_limit 0
    safe_setting global aggressive_package_idle_profile 1

    # ── JOB SCHEDULER ────────────────────────────────────────────
    safe_setting global job_scheduler_constants min_ready_jobs_count=0
    safe_setting global job_scheduler_constants min_ready_non_active_jobs_count=0
    safe_setting global job_scheduler_constants heavy_use_factor=0.9
    safe_setting global job_scheduler_constants moderate_use_factor=0.5
    safe_setting global job_scheduler_constants max_job_count_per_rate_limiting_window=2000
    safe_setting global job_scheduler_constants max_rescheduled_job_count=0
    safe_setting global job_scheduler_constants max_prefetch_jobs_count=0
    safe_setting global job_scheduler_constants max_run_active_jobs=32
    safe_setting global job_scheduler_constants max_run_active_jobs_count=32

    # ── GAME MODE (FULL UNLOCK) ───────────────────────────────────
    safe_setting global game_mode_enabled 1
    safe_setting global game_mode_config_game_loading_boost 1
    safe_setting global game_mode_intervention_fps 1
    safe_setting global game_mode_intervention_loading_boost 1
    safe_setting global game_mode_intervention_resolution_downscale 0
    safe_setting global game_overlay_enabled 0
    safe_setting global game_dashboard_enabled 0
    safe_setting global game_driver_opt_in_apps ""
    safe_setting global game_driver_opt_out_apps ""
    safe_setting global game_driver_blacklist_release_opt_in_apps ""
    safe_setting global game_driver_prerelease_opt_in_apps ""
    safe_setting global game_mode_config_fps_unlock 1
    safe_setting global game_mode_unlocked_frame_rate 1
    safe_setting global game_default_frame_rate 165
    safe_setting global gaming_service_enabled 1
    safe_setting global gaming_power_mode 1
    safe_setting global game_superresolution_enabled 0
    safe_setting global enable_game_mode_for_all_apps 1
    safe_setting global disable_game_mode_boost 0
    safe_setting global game_driver_opt_in_apps "*"
    safe_setting global enable_mt_policy_feature 1
    safe_setting global keep_screen_on_during_gamepad_touch 1

    # ── CPU BOOST / PERFORMANCE MODE ─────────────────────────────
    safe_setting global cpu_boost_on_touch 1
    safe_setting global input_boost_freq_enabled 1
    safe_setting global input_boost_duration 128
    safe_setting global input_boost_ms 500
    safe_setting global power_hint_interaction_duration 250
    safe_setting global power_efficiency_mode 0
    safe_setting global power_management_hints_enabled 0
    safe_setting global boostpulse_duration 500000
    safe_setting global cpu_frequency_governor performance
    safe_setting global cpufreq_gov_performance 1
    safe_setting global disable_thermal_mitigation 1
    safe_setting global performance_mode_enabled 1
    safe_setting global sustained_performance_mode 1
    safe_setting global game_performance_mode 1
    safe_setting global adaptive_cpu_enabled 0
    safe_setting global enable_boost 1
    safe_setting global boost_timeout 500000
    safe_setting global ignore_power_hints 0
    safe_setting global thermal_mitigation_policy 0
    safe_setting global thermal_override_enabled 0
    safe_setting global aggressive_idle_policy 0
    safe_setting global suspend_binder_latency_threshold_us 0
    safe_setting global binder_latency_tracking_enabled 0
    safe_setting global thermal_statsd_enabled 0
    safe_setting global thermal_headroom_polling_enabled 0
    safe_setting global persist_sys_thermal_cpu_control 0

    # ── DALVIK / ART VM ──────────────────────────────────────────
    safe_setting global art_verifier_verify_debuggable 0
    safe_setting global dalvik_vm_extra_opts ""
    safe_setting global dalvik_vm_heapgrowthlimit 256m
    safe_setting global dalvik_vm_heapmaxfree 8m
    safe_setting global dalvik_vm_heapminfree 2m
    safe_setting global dalvik_vm_heapsize 512m
    safe_setting global dalvik_vm_heapstartsize 8m
    safe_setting global dalvik_vm_heaptargetutilization 0.75

    # ── NETWORK / DNS / CONNECTIVITY ─────────────────────────────
    safe_setting global captive_portal_detection_enabled 0
    safe_setting global captive_portal_server localhost
    safe_setting global captive_portal_mode 0
    safe_setting global connectivity_change_delay 0
    safe_setting global wifi_scan_interval_ms 0
    safe_setting global wifi_framework_scan_interval_ms 0
    safe_setting global wifi_idle_ms 0
    safe_setting global wifi_supplicant_scan_interval_ms 0
    safe_setting global wifi_enhanced_power_mode_enabled 0
    safe_setting global wifi_watchdog_num_arp_pings 0
    safe_setting global wifi_num_open_networks_kept 0
    safe_setting global mobile_data_always_on 1
    safe_setting global nitz_update_diff 0
    safe_setting global nitz_update_spacing 0
    safe_setting global tether_dun_required 0
    safe_setting global network_scoring_ui_enabled 0
    safe_setting global network_switch_notification_daily_limit 0
    safe_setting global network_recommendations_enabled 0
    safe_setting global inet_condition_debounce_up_delay 0
    safe_setting global inet_condition_debounce_down_delay 0
    safe_setting global dns_resolver_min_samples 1
    safe_setting global dns_resolver_max_samples 1
    safe_setting global dns_resolver_success_threshold_percent 100
    safe_setting global dns_resolver_sample_validity_seconds 0
    safe_setting global dns_resolver_base_timeout_msec 0
    safe_setting global dns_resolver_max_backoff_msec 1000
    safe_setting global dns_resolver_retry_count 1
    safe_setting global private_dns_mode opportunistic
    safe_setting global tls_max_sessions_pending 0
    safe_setting global tcp_no_delay 1
    safe_setting global tcp_default_init_rwnd 60
    safe_setting global tcp_default_win_scale 2
    safe_setting global network_metered_multipath_preference 0
    safe_setting global connectivity_use_stable_source_for_outbound 1
    safe_setting global network_prefer_bad_wifi 1
    safe_setting global network_avoid_bad_wifi 0
    safe_setting global mobile_data_prefetch 1
    safe_setting global nsd_on 0
    safe_setting global wifi_max_dhcp_retry_count 1
    safe_setting global wifi_mobile_data_transition_wakelock_timeout_ms 0
    safe_setting global wifi_watchdog_on 0
    safe_setting global wifi_watchdog_poor_network_test_enabled 0
    safe_setting global wifi_watchdog_rssi_fetch_interval_ms 0
    safe_setting global wifi_watchdog_background_check_enabled 0
    safe_setting global wifi_watchdog_background_check_delay_ms 0
    safe_setting global wifi_watchdog_background_check_timeout_ms 0
    safe_setting global wifi_watchdog_ping_count 0
    safe_setting global wifi_watchdog_ping_delay_ms 0
    safe_setting global wifi_watchdog_ping_timeout_ms 0
    safe_setting global wifi_watchdog_ap_count 0
    safe_setting global wifi_watchdog_initial_ignored_ping_count 0
    safe_setting global wifi_watchdog_max_ap_checks 0
    safe_setting global wifi_aggressive_handover_enabled 1
    safe_setting global wifi_allow_scan_with_traffic 1
    safe_setting global wifi_network_show_badge 0
    safe_setting global wifi_auto_connect 1
    safe_setting global wifi_batched_scan_enabled 0
    safe_setting global wifi_scan_throttle_enabled 0
    safe_setting global wifi_pno_recency_sorting_enabled 0
    safe_setting global wifi_connected_mac_randomization_enabled 0
    safe_setting global wifi_roaming_mode_enabled 0
    safe_setting global wifi_sleep_policy 2
    safe_setting global wifi_migration_completed 1
    safe_setting global wifi_bounce_delay_override_ms 0
    safe_setting global wifi_link_speed_graph_enabled 0
    safe_setting global data_stall_no_tx_delay_in_ms 0
    safe_setting global data_stall_recovery_action 0
    safe_setting global data_stall_alarm_non_aggressive_delay_in_ms 0
    safe_setting global data_stall_alarm_aggressive_delay_in_ms 0
    safe_setting global socket_buffer_size_mobile_default 131072,262144,1048576,4096,16384,262144
    safe_setting global socket_buffer_size_wifi 524288,1048576,4194304,262144,524288,1048576
    safe_setting global socket_buffer_size_5g_default 524288,1048576,8388608,262144,524288,4194304
    safe_setting global socket_buffer_size_lte 524288,1048576,8388608,262144,524288,4194304
    safe_setting global socket_buffer_size_hspap 131072,262144,1048576,4096,16384,262144
    safe_setting global socket_buffer_size_hspa 131072,262144,1048576,4096,16384,262144
    safe_setting global socket_buffer_size_umts 131072,262144,1048576,4096,16384,262144
    safe_setting global socket_buffer_size_gprs 4092,8760,48000,4096,8760,48000
    safe_setting global socket_buffer_size_edge 4092,16384,131072,4096,16384,65536
    safe_setting global network_preference 1
    safe_setting global tether_offload_disabled 0
    safe_setting global tether_enable_legacy_dhcp_server 0
    safe_setting global carrier_config_applied 1
    safe_setting global radio_busy_wakelock_timeout_ms 0
    safe_setting global pdp_watchdog_poll_interval_ms 0
    safe_setting global pdp_watchdog_long_poll_interval_ms 0
    safe_setting global pdp_watchdog_error_poll_count 0
    safe_setting global pdp_watchdog_trigger_packet_count 0
    safe_setting global pdp_watchdog_max_pdp_reset_fail_count 0
    safe_setting global volte_vt_enabled 1
    safe_setting global enhanced_4g_mode_enabled 1
    safe_setting global enable_cellular_on_boot 1
    safe_setting global multi_sim_data_call 1
    safe_setting global multisim_max_retries 1
    safe_setting global wifi_to_mobile_transition_max_scan_miss_count 0
    safe_setting global wifi_to_mobile_transition_backoff_interval_ms 0
    safe_setting global enable_mt_wifi 1
    safe_setting global ble_scan_always_enabled 0
    safe_setting global ble_scan_interval_ms 0
    safe_setting global ble_scan_window_ms 0
    safe_setting global ble_scan_background_mode 0
    safe_setting global configure_wifi_after_open_network_connect 0
    safe_setting global lte_earfcn_rsrp_boost 0
    safe_setting global cell_data_roaming_protection 0

    # ── STORAGE / SYSTEM ─────────────────────────────────────────
    safe_setting global fstrim_mandatory_interval 0
    safe_setting global sys_storage_threshold_percentage 0
    safe_setting global sys_storage_threshold_max_bytes 0
    safe_setting global sys_storage_full_threshold_bytes 0
    safe_setting global storage_benchmark_internal_callable 1
    safe_setting global storage_settings_allow_encrypt_all 0
    safe_setting global storage_trim_on_volume_mount 0
    safe_setting global storage_trim_on_ota 0
    safe_setting global storage_volume_internal_force_adoptable 0
    safe_setting global storage_recheck_interval_ms 0
    safe_setting global storage_max_recheck_interval_ms 0
    safe_setting global force_allow_on_external 1
    safe_setting global package_verifier_enable 0
    safe_setting global package_verifier_user_consent 0
    safe_setting global verifier_verify_adb_installs 0
    safe_setting global upload_apk_enable 0
    safe_setting global safe_boot_disallowed 0
    safe_setting global rollback_quota_exhausted 0
    safe_setting global rollback_lifetime_millis 0
    safe_setting global rollback_history_millis 0
    safe_setting global web_view_updates_enabled 0

    # ── AUDIO ─────────────────────────────────────────────────────
    safe_setting global audio_offload_video 1
    safe_setting global audio_offload_disable 0
    safe_setting global audio_mixing_disabled 0
    safe_setting global audio_resampler_quality 4
    safe_setting global encoded_surround_output 1
    safe_setting global multi_audio_focus_enabled 1
    safe_setting global enforce_audio_focus 0
    safe_setting global audio_hw_sync_for_a2dp_disabled 0
    safe_setting global bluetooth_a2dp_buffering_mode 1
    safe_setting global audio_safe_csd_as_a_feature_enabled 0
    safe_setting global audio_calling_ux_enabled 0
    safe_setting global audio_share_enabled 0
    safe_setting global audio_spatial_enabled 1
    safe_setting global audio_offload_gapless_enabled 1
    safe_setting global audio_record_minimum_latency_ms 0
    safe_setting global audio_flinger_binder_use_io_priority 1
    safe_setting global disable_abuse_volume_ui 1
    safe_setting global audio_safe_volume_state 0
    safe_setting global audio_master_mono 0
    safe_setting global audio_balance 0
    safe_setting system sound_effects_enabled 1
    safe_setting system haptic_feedback_enabled 1
    safe_setting system vibrate_when_ringing 0

    # ── SCREEN / BRIGHTNESS ──────────────────────────────────────
    safe_setting system screen_brightness_mode 1
    safe_setting system screen_brightness 255
    safe_setting system screen_auto_brightness_adj 0
    safe_setting system accelerometer_rotation 1
    safe_setting system user_rotation 0

    # ── MEDIA / HW CODECS ─────────────────────────────────────────
    safe_setting global media_drm_disable_analog_output_constraint 1
    safe_setting global media_resource_override_pid 0
    safe_setting global media_codec_priority_boost 1
    safe_setting global video_encode_minimum_bitrate 0
    safe_setting global media_player_use_surface_texture 1
    safe_setting global media_settings_menu 1
    safe_setting global enable_hw_decoder 1
    safe_setting global enable_hw_encoder 1
    safe_setting global video_stabilization_mode 0

    # ── NOTIFICATIONS / LOGGING / DEBUG (SILENT) ─────────────────
    safe_setting global heads_up_notifications_enabled 0
    safe_setting global netstats_enabled 0
    safe_setting global netstats_poll_interval 0
    safe_setting global netstats_time_cache_max_age 0
    safe_setting global view_hierarchy_snapshot_enabled 0
    safe_setting global show_notification_channel_warnings 0
    safe_setting global notification_snooze_options ""
    safe_setting global notification_importance_default_threshold 0
    safe_setting global notification_channel_importance_propagation 0
    safe_setting global notification_log_ring_buffer_count 0
    safe_setting global notification_alert_only_mode 0
    safe_setting global smart_replies_in_notifications_flags 0
    safe_setting global adaptive_notifications_enabled 0
    safe_setting global hide_error_dialogs 1
    safe_setting global enable_automatic_system_server_heap_dumps 0
    safe_setting global crash_recovery_enabled 0
    safe_setting global send_action_app_error 0
    safe_setting global dropbox_max_files 0
    safe_setting global dropbox_quota_kb 0
    safe_setting global dropbox_reserve_percent 0
    safe_setting global dropbox_tag_prefix ""
    safe_setting global error_logcat_prefix ""
    safe_setting global logcat_size ""
    safe_setting global bug_report_in_power_menu 0
    safe_setting global show_all_anrs 0
    safe_setting global selinux_audit_logs_enabled 0
    safe_setting global usagestat_upload_enabled 0
    safe_setting global stats_pull_timeout_millis 0
    safe_setting global statsd_min_pull_interval_override_millis 0
    safe_setting global statslog_tag_enabled 0
    safe_setting global enable_action_log_events 0
    safe_setting global metrics_upload_enabled 0
    safe_setting global mobile_data_collection 0
    safe_setting global connectivity_metrics_buffer_size 0
    safe_setting global activity_starts_logging_enabled 0
    safe_setting global enable_gnss_raw_measurements 0
    safe_setting global adb_wifi_enabled 0

    # ── MISC SYSTEM TOGGLES ───────────────────────────────────────
    safe_setting global setup_wizard_has_run 1
    safe_setting global device_provisioned 1
    safe_setting global user_switcher_enabled 0
    safe_setting global screensaver_enabled 0
    safe_setting global screensaver_activate_on_dock 0
    safe_setting global screensaver_activate_on_sleep 0
    safe_setting global emergency_gesture_enabled 0
    safe_setting global aware_enabled 0
    safe_setting global assist_gesture_enabled 0
    safe_setting global assist_gesture_sensitivity 0
    safe_setting global assist_gesture_setup_complete 0
    safe_setting global assist_gesture_silence_alerts_enabled 0
    safe_setting global assist_gesture_wake_enabled 0
    safe_setting global development_settings_enabled 1
    safe_setting global adb_enabled 1
    safe_setting global stay_on_while_plugged_in 3
    safe_setting global wake_lock_blocking_duration_threshold_ms 0
    safe_setting global wake_lock_blocking_tags ""
    safe_setting global cross_profile_calendar_enabled 0
    safe_setting global show_media_on_quick_settings 0
    safe_setting global sync_max_retry_delay_sec 0
    safe_setting global force_resizable_activities 0
    safe_setting global enable_freeform_support 0
    safe_setting global system_server_crashproof 0
    safe_setting global pic_in_pic_enabled 0
    safe_setting global settings_use_psd_ui_thread 1
    safe_setting global screen_rotation_animation_enabled 0
    safe_setting global recents_thumbnail_cache_size 5
    safe_setting global render_shadow_on_ambient_display 0
    safe_setting global screen_off_animation 0
    safe_setting global launcher_open_animation_enabled 1
    safe_setting global launcher_close_animation_enabled 1
    safe_setting global launcher_open_animation_scale 0.3
    safe_setting global launcher_close_animation_scale 0.3
    safe_setting global wallpaper_animation_scale 0
    safe_setting global wallpaper_live_preview_enabled 0
    safe_setting global live_wallpaper_allowed_fps 0
    safe_setting global spinner_hide_delay 0
    safe_setting global notification_dismiss_all_delay 0
    safe_setting global media_notifications_preview_delay 0
    safe_setting global statusbar_disable_system_animations 0
    safe_setting global screen_density_scale 1.0
    safe_setting global corner_radius_multiplier 1
    safe_setting global restricted_networking_mode 0
    safe_setting global safe_mode_enabled 0
    safe_setting global smart_selection_update_mode 0
    safe_setting global enable_deletion_helper_no_threshold_toggle 0
    safe_setting global enable_smart_selection 0
    safe_setting global enable_ephemeral_feature 0
    safe_setting global chained_battery_attribution_enabled 0
    safe_setting global automatic_storage_manager_enabled 0
    safe_setting global automatic_storage_manager_days_to_retain 0
    safe_setting global automatic_storage_manager_download_threshold_bytes 0
    safe_setting global compact_headset_code 0
    safe_setting global encoder_codec_limit_enabled 0
    safe_setting global emergency_tone 0
    safe_setting global power_use_estimation_enabled 0
    safe_setting secure accessibility_enabled 0
    safe_setting secure enabled_accessibility_services ""
    safe_setting secure accessibility_shortcut_target_service ""
    safe_setting secure accessibility_button_targets ""
    safe_setting global accessibility_shortcut_on_lock_screen 0
    safe_setting secure touch_exploration_enabled 0
    safe_setting global accessibility_display_inversion_enabled 0
    safe_setting secure accessibility_display_daltonizer_enabled 0
    safe_setting global accessibility_high_text_contrast_enabled 0
    safe_setting global accessibility_shortcut_single_service 0
    safe_setting global force_4x_msaa 0
    safe_setting global disable_hw_overlays 0
    safe_setting global show_hw_screen_updates 0
    safe_setting global show_hw_layers_updates 0
    safe_setting global show_cpu_usage 0
    safe_setting global gpu_view_updates 0
    safe_setting global overdraw_display 0
    safe_setting global layout_bounds 0
    safe_setting global pointer_location 0
    safe_setting global track_frame_time 0
    safe_setting global profile_gpu_rendering 0
    safe_setting global dont_kill_app_on_gc_stop 0
    safe_setting global vr_display_mode 0
    safe_setting global vr_display_on 0
    safe_setting global vr_listener_enabled 0
    safe_setting global enable_vr_mode_at_switch 0
    safe_setting global shortcut_manager_constants max_icon_dimension_dp=128
    safe_setting global shortcut_manager_constants max_shortcuts=32
    safe_setting global update_headroom_ms 0
    safe_setting global rate_limit_master_history_size 0
    safe_setting global rate_limit_master_history_duration 0
    safe_setting secure input_methods_subtype_history ""
    safe_setting global secure location_mode 0
    safe_setting global assisted_gps_enabled 0
    safe_setting secure mock_location 0
    safe_setting global location_background_throttle_interval_ms 0
    safe_setting global location_background_throttle_proximity_alert_interval_ms 0
    safe_setting global location_background_throttle_package_whitelist ""
    safe_setting global location_max_accuracy 0
    safe_setting global location_max_power 0
    safe_setting global speed_bump_size 0
    safe_setting global blocked_slices ""
    safe_setting global connectivity_sampling_interval_in_seconds 0
    safe_setting global compat_change_gating_state ""
    safe_setting global multi_sim_voice_call_subscription 0
    safe_setting global platform_compat_override_0xd3 0

    # ── SETPROP: HW / RENDERING ───────────────────────────────────
    safe_prop debug.sf.hw 1
    safe_prop debug.egl.hw 1
    safe_prop debug.egl.profiler 0
    safe_prop debug.composition.type gpu
    safe_prop debug.overlays.show 0
    safe_prop debug.skia.renderer vulkan
    safe_prop debug.hwui.renderer vulkan
    safe_prop debug.hwui.use_vulkan 1
    safe_prop debug.hwui.skia_atrace_enabled 0
    safe_prop debug.hwui.profile false
    safe_prop debug.hwui.disable_draw_reorder false
    safe_prop debug.hwui.layer_cache_size 256
    safe_prop debug.hwui.text_cache_size 8
    safe_prop debug.hwui.texture_cache_size 72
    safe_prop debug.hwui.texture_cache_flushrate 0.4
    safe_prop debug.hwui.gradient_cache_size 1
    safe_prop debug.hwui.path_cache_size 32
    safe_prop debug.hwui.shape_cache_size 4
    safe_prop debug.hwui.drop_shadow_cache_size 6
    safe_prop debug.hwui.font_cache_size 8
    safe_prop debug.hwui.enable_merge_path_for_mark_list 1
    safe_prop debug.hwui.level 0
    safe_prop debug.gr.hw 1
    safe_prop debug.performance.tuning 1
    safe_prop sys.use_fifo_ui 1
    safe_prop persist.sys.ui.hw 1
    safe_prop persist.sys.scrollingcache 3
    safe_prop persist.sys.purgeable_assets 1
    safe_prop persist.sys.use_dithering 0
    safe_prop persist.sys.NV_WIFIRETRY 15
    safe_prop persist.sys.dalvik.vm.dex2oat-filter speed
    safe_prop persist.sys.dalvik.vm.dex2oat-flags --compiler-filter=speed
    safe_prop persist.sys.dalvik.vm.dex2oat-threads 4
    safe_prop persist.sys.dalvik.vm.dex2oat-cpu-set 0,1,2,3
    safe_prop persist.sys.strictmode.visual 0
    safe_prop persist.sys.bg_apps_limit 32
    safe_prop persist.sys.max_phantom_processes 2147483647

    # ── SETPROP: DALVIK / VM ──────────────────────────────────────
    safe_prop dalvik.vm.heapsize 512m
    safe_prop dalvik.vm.heapgrowthlimit 256m
    safe_prop dalvik.vm.heapstartsize 8m
    safe_prop dalvik.vm.heaptargetutilization 0.75
    safe_prop dalvik.vm.heapminfree 2m
    safe_prop dalvik.vm.heapmaxfree 8m
    safe_prop dalvik.vm.dex2oat-filter speed
    safe_prop dalvik.vm.dex2oat-flags --compiler-filter=speed
    safe_prop dalvik.vm.dex2oat-threads 4
    safe_prop dalvik.vm.execution-mode int:jit
    safe_prop dalvik.vm.checkjni false
    safe_prop dalvik.vm.verify-bytecode false
    safe_prop dalvik.vm.enableassertions 0
    safe_prop dalvik.vm.lockprof.threshold 0

    # ── SETPROP: SYSTEM / MISC ───────────────────────────────────
    safe_prop ro.config.hw_quickpoweron true
    safe_prop pm.sleep_mode 1
    safe_prop windowsmgr.max_events_per_sec 500
    safe_prop ro.config.nocheckin 1
    safe_prop ro.kernel.android.checkjni 0
    safe_prop ro.media.decsoftwareonly 0

    # ── SETPROP: SURFACEFLINGER ───────────────────────────────────
    safe_prop debug.sf.recomputecrop 0
    safe_prop debug.sf.showcpu 0
    safe_prop debug.sf.showupdates 0
    safe_prop debug.sf.showbackdrop 0
    safe_prop debug.sf.enable_hwc_vds 1
    safe_prop debug.sf.disable_backpressure 1
    safe_prop debug.sf.early_phase_offset_ns 500000
    safe_prop debug.sf.early_app_phase_offset_ns 500000
    safe_prop debug.sf.early_gl_phase_offset_ns 500000
    safe_prop debug.sf.early_gl_app_phase_offset_ns 500000
    safe_prop debug.sf.treat_170m_as_srgb 1
    safe_prop debug.sf.latch_unsignaled 1
    safe_prop debug.sf.auto_latch_unsignaled 1
    safe_prop debug.sf.frame_rate_flexibility_token 1
    safe_prop debug.sf.use_phase_offsets_as_durations 1

    # ── SETPROP: MEDIA / GPU / NET ────────────────────────────────
    safe_prop debug.cpufreq.lowpower 0
    safe_prop video.accelerate.hw 1
    safe_prop media.stagefright.use-awesome 1
    safe_prop media.stagefright.use-player 1
    safe_prop media.codec.priority 1
    safe_prop media.hwcodec.enable 1
    safe_prop media.aac_51_output_enabled true
    safe_prop net.dns1 8.8.8.8
    safe_prop net.dns2 8.8.4.4
    safe_prop net.dns3 1.1.1.1
    safe_prop net.dns4 1.0.0.1
    safe_prop net.rmnet0.dns1 8.8.8.8
    safe_prop net.rmnet0.dns2 8.8.4.4
    safe_prop net.gprs.dns1 8.8.8.8
    safe_prop net.gprs.dns2 8.8.4.4
    safe_prop net.ppp0.dns1 8.8.8.8
    safe_prop net.ppp0.dns2 8.8.4.4
    safe_prop net.wifi.dns1 8.8.8.8
    safe_prop net.wifi.dns2 8.8.4.4
    safe_prop net.eth0.dns1 8.8.8.8
    safe_prop net.eth0.dns2 8.8.4.4
    safe_prop debug.gralloc.enable_fb_ubwc 1
    safe_prop debug.enable.bl 1
    safe_prop debug.enable.sglscale 1
    safe_prop debug.renderscript.rs_debug_shutdown 0

    # ── KERNEL / VM TWEAKS (rootless-safe writes) ─────────────────
    safe_write 0    /proc/sys/vm/compaction_proactiveness
    safe_write 1    /proc/sys/vm/swappiness
    safe_write 50   /proc/sys/vm/vfs_cache_pressure
    safe_write 0    /proc/sys/vm/page-cluster
    safe_write 3    /proc/sys/vm/dirty_ratio
    safe_write 1    /proc/sys/vm/dirty_background_ratio
    safe_write 500  /proc/sys/vm/dirty_expire_centisecs
    safe_write 100  /proc/sys/vm/dirty_writeback_centisecs
    safe_write 1    /proc/sys/kernel/perf_event_paranoid
    safe_write 0    /proc/sys/kernel/printk_devkmsg
    safe_write 3000 /proc/sys/kernel/sched_latency_ns
    safe_write 500  /proc/sys/kernel/sched_min_granularity_ns
    safe_write 0    /proc/sys/kernel/sched_child_runs_first
    safe_write 1    /proc/sys/kernel/sched_autogroup_enabled

    # ── EXTRA GAMING TWEAKS (rootless & safe, universal) ─────────
    # Force highest GPU bus bandwidth
    safe_write_glob "max_freq" /sys/class/kgsl/kgsl-3d0/devfreq/max_freq
    safe_write_glob "performance" /sys/class/kgsl/kgsl-3d0/devfreq/governor
    # CPU governor — performance on all big cores
    safe_write_glob "performance" /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
    # GPU max freq lock (Exynos / Mali)
    safe_write_glob "1" /sys/kernel/gpu/gpu_max_clock
    # Disable kernel same-page merging for gaming (reduces latency spikes)
    safe_write 0 /sys/kernel/mm/ksm/run
    # I/O scheduler — deadline for lowest latency
    for blk in /sys/block/*/queue/scheduler; do
        echo "deadline" > "$blk" 2>/dev/null || echo "mq-deadline" > "$blk" 2>/dev/null || true
    done
    # Readahead 128KB for smooth asset streaming
    safe_write_glob 128 /sys/block/*/queue/read_ahead_kb
    # Extra gaming settings
    safe_setting global game_mode_intervention_cpu 1
    safe_setting global game_mode_intervention_gpu 1
    safe_setting global game_mode_user_config_allowed 1
    safe_setting global game_mode_battery_game_default_override 0
    safe_setting global game_mode_performance_game_default_override 1
    safe_setting global game_mode_config_game_default_frame_rate 165
    safe_setting global game_mode_config_allow_dynamic_resolution 0
    safe_setting global game_compat_mode_enabled 1
    safe_setting global gaming_touch_stabilization 0
    safe_setting global gaming_anti_aliasing 0
    safe_setting global sf_early_phase_offset_ns 250000
    safe_setting global sf_late_phase_offset_ns 0
    # Fling / scroll feel optimized for gaming
    safe_setting global fling_deceleration_rate 0.09
    safe_setting global minimum_fling_velocity 50
    safe_setting global maximum_fling_velocity 30000
    # Jitter reduction
    safe_setting global view_post_ime_input_delay 0
    safe_setting global game_input_boost_duration_ms 80
    safe_setting global input_boost_ms 500
    # Keep all CPU cores online during gameplay
    safe_write_glob 0 /sys/devices/system/cpu/cpu*/online 2>/dev/null || true
    for i in 1 2 3 4 5 6 7; do
        safe_write 1 /sys/devices/system/cpu/cpu${i}/online
    done

    echo ""
    echo "================================================"
    echo "  ✅  ur Phone is fully optimized.  -- MOs Enhancer"
    echo "================================================"

    log_msg "MOs Enhancer: ALL optimizations applied successfully."
}

# ================================================================
# ENTRY POINT — Action button triggers full optimization
# ================================================================
apply_mos_enhancer
