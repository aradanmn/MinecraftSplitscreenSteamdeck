FROM ubuntu:24.04

# Simulate the Steam Deck / Bazzite environment:
# - Same bash version, jq, curl, flatpak stub, udev
# - No display (tests mock xdpyinfo / KWin)
# - Python3 available (for placeholder window tests)

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    bats \
    curl \
    jq \
    python3 \
    python3-tk \
    flatpak \
    udev \
    inotify-tools \
    xdotool \
    xterm \
    util-linux \
    sed \
    gawk \
    grep \
    coreutils \
    git \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Create fake /dev/input structure with js and event devices
RUN mkdir -p /dev/input && \
    for i in 0 1 2 3; do \
        touch /dev/input/js${i}; \
        touch /dev/input/event${i}; \
    done

# Create fake sysfs Bluetooth serials for 4 controllers
RUN for i in 0 1 2 3; do \
        mkdir -p /sys/class/input/event${i}/device; \
        printf "aa:bb:cc:dd:ee:0%d\n" "${i}" > /sys/class/input/event${i}/device/uniq; \
    done

WORKDIR /project

COPY . .

# Make test helpers and scripts executable
RUN chmod +x tests/bats-install/bin/bats 2>/dev/null || true && \
    chmod +x tests/run_tests.sh

CMD ["tests/run_tests.sh"]
