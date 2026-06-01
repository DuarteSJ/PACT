#!/bin/bash
#
# Machine-prep helpers for PACT experiments (sourced by prepare_environment.sh
# and modify-uncore-freq.sh).  Self-contained: only uses standard tools
# (numactl, lscpu) and sysfs/proc knobs — no external globals or profilers.

#-------------------------------------------------------------------------------

flush_fs_caches() {
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1
    sleep 10
}

disable_nmi_watchdog() {
    echo 0 | sudo tee /proc/sys/kernel/nmi_watchdog >/dev/null 2>&1
}

disable_turbo() {
    echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo >/dev/null 2>&1
}

# 0: no randomization, everything is static
# 1: conservative randomization, shared libraries, stack, mmap(), VDSO and heap
# are randomized
# 2: full randomization, the above points in 1 plus brk()
disable_va_aslr() {
    echo 0 | sudo tee /proc/sys/kernel/randomize_va_space >/dev/null 2>&1
}

disable_swap() {
    sudo swapoff -a
}

disable_ksm() {
    echo 0 | sudo tee /sys/kernel/mm/ksm/run >/dev/null 2>&1
}

disable_numa_balancing() {
    echo 0 | sudo tee /proc/sys/kernel/numa_balancing >/dev/null 2>&1
}

# disable transparent hugepages
disable_thp() {
    echo "never" | sudo tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null 2>&1
}

disable_ht() {
    echo off | sudo tee /sys/devices/system/cpu/smt/control >/dev/null 2>&1
}

bring_all_cpus_online() {
    echo 1 | sudo tee /sys/devices/system/cpu/cpu*/online >/dev/null 2>&1
}

set_performance_mode() {
    #echo "  ===> Placing CPUs in performance mode ..."
    for governor in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo performance | sudo tee $governor >/dev/null 2>&1
    done
}

# Place CPUs in the performance governor.  (The original additionally launched a
# custom 'pmqos' latency helper from a hard-coded path; that dependency has been
# removed so the prep is self-contained.)
check_pmqos() {
    set_performance_mode
}

# Keep all cores on Node 0 online while keeping all cores on Node 1 offline
configure_cxl_exp_cores() {
    # To be safe, let's bring all the cores online first
    echo 1 | sudo tee /sys/devices/system/cpu/cpu*/online >/dev/null 2>&1

    # Disable all cores on Node 1
    echo 0 | sudo tee /sys/devices/system/node/node1/cpu*/online >/dev/null 2>&1
}

configure_base_exp_cores() {
    # To be safe, let's bring all the cores online first
    echo 1 | sudo tee /sys/devices/system/cpu/cpu*/online >/dev/null 2>&1
    # Leave half of the cores online for both Node 0 and Node 1
    local cores_per_socket=$(lscpu | grep -i 'Core(s) per socket' | awk '{print $4}')
    local half_cores_per_socket=$((cores_per_socket / 2))
    local total_cores=$((cores_per_socket * 2))
    for ((i = half_cores_per_socket; i < cores_per_socket; i++)); do
        echo 0 | sudo tee /sys/devices/system/cpu/cpu$i/online >/dev/null 2>&1
    done

    for ((i = cores_per_socket + half_cores_per_socket; i < total_cores; i++)); do
        echo 0 | sudo tee /sys/devices/system/cpu/cpu$i/online >/dev/null 2>&1
    done
}

check_base_conf() {
    disable_nmi_watchdog
    disable_va_aslr
    disable_ksm
    disable_numa_balancing
    disable_thp
    disable_ht
    disable_turbo
    configure_base_exp_cores
    check_pmqos
    disable_swap

    nc=$(sudo numactl --hardware | grep 'node 1 cpus' | awk -F: '{print $2}')

    # Everything looks correct
    [[ ! -z $nc ]] && return

    # Bummer, let's try bring the cores on Node 1 up...
    echo "===> Warning: Base experiment environment NOT properly setup"
    echo "     All cores on Node 1 are offline..."

    echo "===> Enabling all the cores on Node 1 now ..."
    echo 1 | sudo tee /sys/devices/system/node/node1/cpu*/online >/dev/null 2>&1

    nc=$(sudo numactl --hardware | grep 'node 1 cpus' | awk -F: '{print $2}')
    [[ -z $nc ]] && echo "===> Failed to bring up all the cores on Node 1 for Base experiments ..." && exit

    sleep 60
}

check_cxl_conf() {
    disable_nmi_watchdog
    disable_va_aslr
    disable_ksm
    disable_numa_balancing
    disable_thp
    disable_ht
    disable_turbo
    configure_cxl_exp_cores
    check_pmqos
    disable_swap

    nc=$(sudo numactl --hardware | grep 'node 1 cpus' | awk -F: '{print $2}')

    # Everything looks correct
    [[ -z $nc ]] && return

    # Node 1 still has online cores: CXL emulation is NOT set up. Retry the
    # offlining, and abort if it still fails — proceeding with the slow tier's
    # cores online produces invalid results, so fail loudly rather than warn.
    echo "===> Warning: CXL experiment environment NOT properly setup"
    echo "     I see online cores [$nc] on Node 1; retrying offline..."

    echo "===> Disabling all the cores on Node 1 now ..."
    echo 0 | sudo tee /sys/devices/system/node/node1/cpu*/online >/dev/null 2>&1

    nc=$(sudo numactl --hardware | grep 'node 1 cpus' | awk -F: '{print $2}')
    [[ ! -z $nc ]] && {
        echo "===> ERROR: could not offline Node 1 cores for CXL emulation."
        echo "     The slow (CXL-like) tier must be CPU-less; aborting to avoid"
        echo "     invalid measurements."
        exit 1
    }

    sleep 60
}
