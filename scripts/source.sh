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

# KernelSU forks compute their version from the commit count, and several
# read it straight out of the enclosing git repo. A depth-1 clone reports 1
# commit, which produces a nonsense version. Unshallow just enough to count.
if [ -f "${KERNEL_DIR}/.git/shallow" ]; then
	debug "kernel tree is shallow; that is fine for building"
fi

group "Injecting AMOLED display techpack"
info "Fetching techpack/display from Fucking-Projekt meme branch..."
git clone -q --depth=1 -b meme https://github.com/Fucking-Projekt/android_kernel_xiaomi_stone "${WORKSPACE}/display_src"
rm -rf "${KERNEL_DIR}/techpack/display"
cp -r "${WORKSPACE}/display_src/techpack/display" "${KERNEL_DIR}/techpack/"
rm -rf "${WORKSPACE}/display_src"

if [ -f "${REPO_ROOT}/patches/display/msm_atomic.c" ]; then
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
	info "Fixing of_graph_is_present for Linux 5.4 in dsi_display.c"
	python3 -c '
import sys
p = sys.argv[1]
with open(p, "r") as f:
    c = f.read()
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
# Allow ALL stock Xiaomi DLKM vendor modules (Camera, WiFi, BT, Audio, Sensors)
# ==============================================================================
if [ -f "${KERNEL_DIR}/kernel/module.c" ]; then
	info "Patching kernel/module.c to unconditionally accept all Xiaomi vendor modules..."
	python3 -c '
import sys
p = sys.argv[1]
with open(p, "r") as f:
    c = f.read()

# 1. Accept vermagic even if different
old_magic = """} else if (!same_magic(modmagic, vermagic, info->index.vers)) {
\t\tpr_err("%s: version magic '%s' should be '%s'\\n",
\t\t       info->name, modmagic, vermagic);
\t\treturn -ENOEXEC;
\t}"""

new_magic = """} else if (!same_magic(modmagic, vermagic, info->index.vers)) {
\t\tpr_warn("%s: version magic '%s' should be '%s', accepting anyway\\n",
\t\t       info->name, modmagic, vermagic);
\t}"""

if old_magic in c:
    c = c.replace(old_magic, new_magic)
    print("Patched same_magic in module.c")

# 2. Accept all symbol CRCs
old_check_ver = """static int check_version(const struct load_info *info,
\t\t\t const char *symname,
\t\t\t struct module *mod,
\t\t\t const s32 *crc)
{"""

new_check_ver = """static int check_version(const struct load_info *info,
\t\t\t const char *symname,
\t\t\t struct module *mod,
\t\t\t const s32 *crc)
{
\treturn 1;"""

if old_check_ver in c:
    c = c.replace(old_check_ver, new_check_ver)
    print("Patched check_version in module.c")

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
sed -i 's/^EXTRAVERSION = .*/EXTRAVERSION = -qgki-g4e27a72000be/' "${KERNEL_DIR}/Makefile"

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
