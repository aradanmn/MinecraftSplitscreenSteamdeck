#!/usr/bin/env bash
# =============================================================================
# VM provision script — run once by `vagrant up`
# Sets up an Ubuntu 24.04 environment that matches the Steam Deck / Bazzite
# target without requiring actual hardware or a full KDE Plasma install.
# =============================================================================

set -euo pipefail

echo "=== Provisioning MC Splitscreen test VM ==="

# ---- System packages --------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y --no-install-recommends \
    bash curl wget jq git ca-certificates \
    openjdk-21-jre-headless \
    flatpak \
    xvfb x11-utils \
    inotify-tools xdotool \
    python3 python3-gi python3-gi-cairo gir1.2-gtk-3.0 \
    bats \
    sed gawk grep coreutils util-linux \
    libfuse2 fuse \
    2>/dev/null

echo "✓ System packages installed"

# ---- PrismLauncher AppImage -------------------------------------------------
PRISM_DIR="/home/vagrant/.local/share/PrismLauncher"
PRISM_APP="/home/vagrant/.local/bin/PrismLauncher"
mkdir -p "$PRISM_DIR" "$(dirname "$PRISM_APP")"

if [[ ! -x "$PRISM_APP" ]]; then
    echo "Downloading PrismLauncher AppImage..."
    # Fetch latest release URL from GitHub API
    PRISM_URL=$(curl -fsSL \
        "https://api.github.com/repos/PrismLauncher/PrismLauncher/releases/latest" \
        | jq -r '.assets[] | select(.name | test("PrismLauncher-Linux-Qt6-Portable.*x86_64.AppImage")) | .browser_download_url' \
        | head -1)

    if [[ -z "$PRISM_URL" ]]; then
        echo "⚠ Could not fetch PrismLauncher URL from GitHub — using stub"
        # Stub: a minimal AppImage placeholder so path detection passes
        cat > "$PRISM_APP" <<'STUB'
#!/usr/bin/env bash
# Stub PrismLauncher for testing — accepts -l / --launch flags, exits cleanly
echo "[PrismLauncher stub] args: $*" >&2
exit 0
STUB
        chmod +x "$PRISM_APP"
    else
        wget -q "$PRISM_URL" -O "$PRISM_APP"
        chmod +x "$PRISM_APP"
        echo "✓ PrismLauncher downloaded"
    fi
else
    echo "✓ PrismLauncher already present"
fi

chown -R vagrant:vagrant /home/vagrant/.local

# ---- Fake joystick devices (4 controllers) ----------------------------------
# Creates /dev/input/jsN and event devices + sysfs Bluetooth serials
# so the installer's controller detection code sees 4 connected controllers.
for i in 0 1 2 3; do
    # Create block devices so existence checks pass
    if [[ ! -e /dev/input/js${i} ]]; then
        mknod /dev/input/js${i} c 13 $((32 + i)) 2>/dev/null || touch /dev/input/js${i}
    fi
    if [[ ! -e /dev/input/event${i} ]]; then
        touch /dev/input/event${i}
    fi

    # Fake sysfs Bluetooth serial (unique MAC per slot)
    SYSFS="/sys/class/input/event${i}/device"
    if [[ ! -f "$SYSFS/uniq" ]]; then
        mkdir -p "$SYSFS"
        printf "aa:bb:cc:dd:ee:0%d\n" "$i" > "$SYSFS/uniq"
    fi
done

echo "✓ Fake joystick devices created (4 controllers)"

# ---- bats-core (local install as fallback) ----------------------------------
if ! command -v bats >/dev/null 2>&1; then
    git clone --depth=1 https://github.com/bats-core/bats-core /project/tests/bats 2>/dev/null || true
    /project/tests/bats/install.sh /project/tests/bats-install 2>/dev/null || true
fi

# ---- PATH for vagrant user --------------------------------------------------
grep -q '\.local/bin' /home/vagrant/.bashrc || \
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> /home/vagrant/.bashrc

echo ""
echo "=== Provision complete ==="
echo ""
echo "Next steps:"
echo "  vagrant snapshot save fresh-install"
echo "  vagrant ssh -c 'cd /project && sudo ./install-minecraft-splitscreen.sh'"
echo "  vagrant ssh -c 'cd /project && tests/vm/run-integration.sh'"
