#!/usr/bin/env bash
# Fetch the kernel source tree.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKSPACE=${WORKSPACE:?WORKSPACE must be set}
KERNEL_DIR="${WORKSPACE}/android-kernel"
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

group "Cloning kernel source"
info "${KERNEL_SOURCE} @ ${KERNEL_SOURCE_BRANCH}"

ref_exists "$KERNEL_SOURCE" "$KERNEL_SOURCE_BRANCH" \
	|| die "branch/tag '${KERNEL_SOURCE_BRANCH}' does not exist in ${KERNEL_SOURCE}"

rm -rf "$KERNEL_DIR"
retry 3 git clone -q --recursive --depth=1 \
	-b "$KERNEL_SOURCE_BRANCH" "$KERNEL_SOURCE" "$KERNEL_DIR" \
	|| die "failed to clone ${KERNEL_SOURCE}"

if [ -f "${KERNEL_DIR}/.git/shallow" ]; then
	debug "kernel tree is shallow; that is fine for building"
fi

if [ -d "${KERNEL_DIR}/techpack/display" ] && [ -d "${KERNEL_DIR}/techpack/dataipa" ]; then
	info "techpack/display and dataipa already present in stone kernel source; keeping native techpack"
else
	group "Injecting AMOLED display techpack"
	info "Fetching techpack/display from Fucking-Projekt meme branch..."
	git clone -q --depth=1 -b meme https://github.com/Fucking-Projekt/android_kernel_xiaomi_stone "${WORKSPACE}/display_src"
	rm -rf "${KERNEL_DIR}/techpack/display"
	cp -r "${WORKSPACE}/display_src/techpack/display" "${KERNEL_DIR}/techpack/"
	rm -rf "${WORKSPACE}/display_src"
fi

if [ -f "${REPO_ROOT}/patches/display/msm_atomic.c" ] && [ ! -d "${KERNEL_DIR}/techpack/dataipa" ]; then
	info "Restoring stock CodeLinaro msm_atomic.c and msm_kms.h (pre-c7dd4e53)"
	cp -v "${REPO_ROOT}/patches/display/msm_atomic.c" "${KERNEL_DIR}/techpack/display/msm/msm_atomic.c"
	cp -v "${REPO_ROOT}/patches/display/msm_kms.h"    "${KERNEL_DIR}/techpack/display/msm/msm_kms.h"
fi
if [ -f "${KERNEL_DIR}/techpack/display/msm/sde/sde_irq.c" ]; then
	info "Fixing generic_handle_irq_safe -> generic_handle_irq for Linux 5.4 in sde_irq.c"
	sed -i 's/generic_handle_irq_safe/generic_handle_irq/g' "${KERNEL_DIR}/techpack/display/msm/sde/sde_irq.c"
fi
if [ -f "${KERNEL_DIR}/techpack/display/msm/msm_drv.c" ]; then
	info "Fixing kthread_run_perf_critical -> kthread_run for Linux 5.4 in msm_drv.c"
	sed -i 's/kthread_run_perf_critical(cpu_perf_mask,/kthread_run(/g' "${KERNEL_DIR}/techpack/display/msm/msm_drv.c"
fi
if [ -f "${KERNEL_DIR}/techpack/display/msm/dsi/dsi_display.c" ]; then
	info "Checking of_graph_is_present for Linux 5.4 in dsi_display.c"
	python3 -c '
import sys
p = sys.argv[1]
with open(p, "r") as f:
    c = f.read()
if "of_graph_is_present" not in c:
    patch = """#include <linux/of_graph.h>
static inline bool of_graph_is_present(const struct device_node *node) {
\tstruct device_node *ports, *port;
\tports = of_get_child_by_name(node, "ports");
\tif (ports) node = ports;
\tport = of_get_child_by_name(node, "port");
\tof_node_put(ports);
\tof_node_put(port);
\treturn !!port;
}
"""
    c = c.replace("#include <linux/err.h>", "#include <linux/err.h>\n" + patch)
    with open(p, "w") as f:
        f.write(c)
' "${KERNEL_DIR}/techpack/display/msm/dsi/dsi_display.c"
fi

# ==============================================================================
# Unblock ALL Xiaomi DLKM vendor modules (Camera, WiFi, BT, Audio, Sensors)
# ==============================================================================

# 1. Export __stack_chk_guard for vendor modules (qca_cld3_wlan, camera, btpower, etc.)
if [ -f "${KERNEL_DIR}/arch/arm64/kernel/process.c" ]; then
	info "Exporting __stack_chk_guard in arch/arm64/kernel/process.c..."
	python3 -c '
import sys
p = sys.argv[1]
with open(p, "r") as f:
    c = f.read()
target = "#if defined(CONFIG_STACKPROTECTOR) && !defined(CONFIG_STACKPROTECTOR_PER_TASK)"
if target in c:
    c = c.replace(target, "#if defined(CONFIG_STACKPROTECTOR)")
    print("Patched __stack_chk_guard in process.c")
else:
    print("Warning: target not found in process.c")
with open(p, "w") as f:
    f.write(c)
' "${KERNEL_DIR}/arch/arm64/kernel/process.c"
fi

if [ -f "${KERNEL_DIR}/arch/arm64/include/asm/stackprotector.h" ]; then
	info "Initializing __stack_chk_guard in arch/arm64/include/asm/stackprotector.h..."
	python3 -c '
import sys
p = sys.argv[1]
with open(p, "r") as f:
    c = f.read()
target = "if (!IS_ENABLED(CONFIG_STACKPROTECTOR_PER_TASK))\n\t\t__stack_chk_guard = current->stack_canary;"
replacement = "__stack_chk_guard = current->stack_canary;"
if target in c:
    c = c.replace(target, replacement)
    print("Patched boot_init_stack_canary in stackprotector.h")
else:
    print("Warning: target not found in stackprotector.h")
with open(p, "w") as f:
    f.write(c)
' "${KERNEL_DIR}/arch/arm64/include/asm/stackprotector.h"
fi

# 2. Patch kernel/module.c to accept all Xiaomi vendor modules unconditionally
if [ -f "${KERNEL_DIR}/kernel/module.c" ]; then
	info "Patching kernel/module.c to unconditionally accept all Xiaomi vendor modules..."
	python3 -c '
import sys
p = sys.argv[1]
with open(p, "r") as f:
    c = f.read()

# 1. same_magic returns 1
c = c.replace("return strcmp(amagic, bmagic) == 0;", "return 1;")
print("Patched same_magic in module.c")

# 2. check_version returns 1 cleanly after declarations
target_chk = "struct modversion_info *versions;"
replacement_chk = "struct modversion_info *versions;\n\n\treturn 1;"
if target_chk in c:
    c = c.replace(target_chk, replacement_chk, 1)
    print("Patched check_version in module.c")
else:
    print("Warning: target_chk not found in module.c")

with open(p, "w") as f:
    f.write(c)
' "${KERNEL_DIR}/kernel/module.c"
fi

if [ -f "${KERNEL_DIR}/scripts/setlocalversion" ]; then
	info "Fixing setlocalversion to prevent git commit hash and -dirty from corrupting vermagic"
	echo "#!/bin/sh" > "${KERNEL_DIR}/scripts/setlocalversion"
	echo 'echo ""' >> "${KERNEL_DIR}/scripts/setlocalversion"
	chmod +x "${KERNEL_DIR}/scripts/setlocalversion"
fi

ok "AMOLED display techpack injected into ${KERNEL_DIR}/techpack/display"
endgroup

info "Locking kernel version to stock 5.4.289-qgki-g4e27a72000be for HyperOS module compatibility"
sed -i 's/^SUBLEVEL = .*/SUBLEVEL = 289/' "${KERNEL_DIR}/Makefile"
sed -i 's/^EXTRAVERSION = .*/EXTRAVERSION =/' "${KERNEL_DIR}/Makefile"

KVER=$(kernel_version "$KERNEL_DIR") \
	|| die "could not read VERSION/PATCHLEVEL from ${KERNEL_DIR}/Makefile -- is this a kernel tree?"
export_env KERNEL_VERSION "$KVER"
export_env KERNEL_DIR "$KERNEL_DIR"
ok "kernel source ready (Linux ${KVER})"
summary "| Kernel | \`${KERNEL_SOURCE##*/}\` @ \`${KERNEL_SOURCE_BRANCH}\` (Linux ${KVER}) |"

# LOCALVERSION is used purely to decorate artifact names.
if is_true "${ADD_LOCALVERSION_TO_FILENAME:-false}" && [ -f "${KERNEL_DIR}/localversion" ]; then
	export_env LOCALVERSION "$(cat "${KERNEL_DIR}/localversion")"
else
	export_env LOCALVERSION ""
fi
endgroup
