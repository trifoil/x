#!/bin/bash

# Xenomai 4 Installation Script for Debian 12 (EVL-Patched Kernel)
# This script automates the installation of Xenomai 4 with linux-evl EVL-patched kernel
# 
# Usage: sudo ./install_xenomai4.sh
# 
# Prerequisites:
# - Root access
# - Internet connectivity
# - At least 15GB free disk space
# - Multi-core CPU recommended for faster compilation

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
    exit 1
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)"
    fi
}

# Check system requirements
check_requirements() {
    log "Checking system requirements..."
    
    # Check available disk space (need at least 15GB)
    local available_space=$(df / | awk 'NR==2 {print $4}')
    local required_space=15728640  # 15GB in KB
    
    if [[ $available_space -lt $required_space ]]; then
        error "Insufficient disk space. Need at least 15GB free, have $(($available_space / 1024 / 1024))GB"
    fi
    
    # Check available memory (need at least 4GB)
    local available_mem=$(free -k | awk 'NR==2 {print $2}')
    local required_mem=4194304  # 4GB in KB
    
    if [[ $available_mem -lt $required_mem ]]; then
        warn "Low memory detected. Installation may be slow or fail. Recommended: 8GB+"
    fi
    
    # Check CPU cores
    local cpu_cores=$(nproc)
    log "Detected $cpu_cores CPU cores"
    
    # Check if we're on Debian
    if [[ ! -f /etc/debian_version ]]; then
        error "This script is designed for Debian systems"
    fi
    
    log "System requirements check passed"
}

# Step 1: Update system and install dependencies
install_dependencies() {
    log "Step 1: Updating system and installing build dependencies..."
    
    # Update package lists
    apt update
    
    # Upgrade system
    apt upgrade -y
    
    # Install essential build tools and dependencies
    apt install -y build-essential devscripts debhelper findutils git \
                   libncurses-dev fakeroot zlib1g-dev curl wget \
                   linux-headers-$(uname -r) libssl-dev libelf-dev \
                   flex bison pkg-config cmake ninja-build libpci-dev \
                   libusb-1.0-0-dev libudev-dev rt-tests bc
    
    log "Dependencies installed successfully"
}

# Step 2: Build linux-evl EVL-patched kernel
build_evl_kernel() {
    log "Step 2: Building linux-evl EVL-patched kernel..."
    
    # Create build directory
    mkdir -p /tmp/linux-evl-build
    cd /tmp/linux-evl-build
    
    # Clone linux-evl repository
    log "Cloning linux-evl repository..."
    git clone --depth 1 --branch v6.6.y-evl-rebase https://source.denx.de/Xenomai/xenomai4/linux-evl.git
    
    cd linux-evl
    
    # Checkout the current LTS branch
    git checkout v6.6.y-evl-rebase
    
    # Copy current kernel config as starting point
    log "Configuring kernel..."
    if [[ -f /proc/config.gz ]]; then
        log "Using /proc/config.gz for kernel configuration..."
        zcat /proc/config.gz > .config
    elif [[ -f /boot/config-$(uname -r) ]]; then
        log "Using /boot/config-$(uname -r) for kernel configuration..."
        cp /boot/config-$(uname -r) .config
    else
        log "No existing kernel config found, generating default configuration..."
        make defconfig
    fi
    
    # Force-enable EVL in kernel config
    ./scripts/config --enable EVL --enable EVL_LATENCY_USER
    
    # Configure kernel for EVL (automatically accept defaults)
    log "Running kernel configuration (accepting defaults)..."
    yes "" | make oldconfig
    
    # Force-enable critical real-time options
    log "Enabling critical real-time options..."
    ./scripts/config --set-val PREEMPT_RT y \
                    --disable PREEMPT_VOLUNTARY \
                    --disable PREEMPT_NONE \
                    --enable NO_HZ_FULL \
                    --enable CPU_ISOLATION \
                    --enable RCU_NOCB_CPU \
                    --enable RCU_BOOST \
                    --set-val RCU_BOOST_DELAY 500
    
    # Handle common configuration conflicts
    ./scripts/config --disable CPU_IDLE \
                    --disable CPU_FREQ \
                    --disable SCHED_AUTOGROUP
    
    # Verify critical configurations
    log "Verifying critical kernel configurations..."
    grep -E "CONFIG_EVL=|CONFIG_PREEMPT_RT=|CONFIG_NO_HZ_FULL=" .config
    
    # Critical safety check
    local required_configs
    required_configs=(
        "CONFIG_EVL=y"
        "CONFIG_PREEMPT_RT=y"
        "CONFIG_NO_HZ_FULL=y"
        "CONFIG_CPU_ISOLATION=y"
    )
    
    for config in "${required_configs[@]}"; do
        if ! grep -q "^$config" .config; then
            error "Missing $config in kernel configuration!"
        fi
    done
    
    log "✓ All critical kernel configurations verified successfully"
    
    # Build the EVL-patched kernel
    local cpu_cores=$(nproc)
    local build_jobs=$((cpu_cores > 4 ? 4 : cpu_cores))
    
    log "Building kernel with $build_jobs parallel jobs (this may take 60-120 minutes)..."
    make -j$build_jobs
    
    log "Building kernel modules..."
    make -j$build_jobs modules
    
    log "Installing kernel modules..."
    make modules_install
    
    log "Installing kernel..."
    make install
    
    log "Creating initramfs..."
    update-initramfs -c -k $(make kernelrelease)
    
    log "Updating GRUB bootloader..."
    update-grub
    
    log "EVL-patched kernel built and installed successfully"
}

# Step 3: Install libevl
install_libevl() {
    log "Step 3: Installing libevl..."
    
    # Create build directory
    mkdir -p /tmp/libevl-build
    cd /tmp/libevl-build
    
    # Clone libevl repository
    log "Cloning libevl repository..."
    git clone https://gitlab.denx.de/Xenomai/libevl.git
    
    cd libevl
    
    # Build and install libevl
    log "Building libevl..."
    make PREFIX=/usr/local
    
    log "Installing libevl..."
    make PREFIX=/usr/local install
    
    # Update shared library cache
    ldconfig
    
    log "libevl installed successfully"
}

# Step 4: Build and install Xenomai 4
install_xenomai4() {
    log "Step 4: Building and installing Xenomai 4..."
    
    # Create build directory
    mkdir -p /tmp/xenomai4-build
    cd /tmp/xenomai4-build
    
    # Clone Xenomai 4 repository
    log "Cloning Xenomai 4 repository..."
    git clone https://gitlab.denx.de/Xenomai/xenomai4.git
    
    cd xenomai4
    
    # Checkout the latest stable release
    log "Checking out Xenomai 4 v4.2.0..."
    git checkout v4.2.0
    
    # Create build directory
    mkdir build
    cd build
    
    # Configure Xenomai 4
    log "Configuring Xenomai 4..."
    cmake -G Ninja -DCMAKE_BUILD_TYPE=Release -DXENO_ENABLE_DOC=ON \
          -DXENO_ENABLE_TESTS=ON -DXENO_ENABLE_DEMO=ON ..
    
    # Build Xenomai 4
    log "Building Xenomai 4..."
    ninja
    
    # Install Xenomai 4
    log "Installing Xenomai 4..."
    ninja install
    
    # Update shared library cache
    ldconfig
    
    log "Xenomai 4 installed successfully"
}

# Step 5: Configure Xenomai 4
configure_xenomai4() {
    log "Step 5: Configuring Xenomai 4..."
    
    # Create Xenomai 4 configuration directory
    mkdir -p /etc/xenomai4
    
    # Copy default configuration
    cp /usr/local/xenomai4/etc/xenomai.conf /etc/xenomai4/
    
    # Set up environment variables
    log "Setting up environment variables..."
    cat >> /etc/profile << 'EOF'
# Xenomai 4 Environment Variables
export XENOMAI_ROOT_DIR=/usr/local/xenomai4
export PATH=$XENOMAI_ROOT_DIR/bin:$PATH
export LD_LIBRARY_PATH=$XENOMAI_ROOT_DIR/lib:$LD_LIBRARY_PATH
export PKG_CONFIG_PATH=$XENOMAI_ROOT_DIR/lib/pkgconfig:$PKG_CONFIG_PATH
EOF
    
    # Create evl group for non-root access
    groupadd evl 2>/dev/null || true
    
    # Add current user to evl group
    usermod -aG evl $SUDO_USER 2>/dev/null || true
    
    # Source the profile for current session
    source /etc/profile
    
    log "Xenomai 4 configured successfully"
}

# Step 6: Post-install optimization
optimize_system() {
    log "Step 6: Applying real-time optimizations..."
    
    # Add real-time tweaks to sysctl
    cat >> /etc/sysctl.conf << 'EOF'
# Real-Time Tweaks
kernel.sched_rt_runtime_us = 950000
kernel.sched_latency_ns = 1000000
kernel.sched_migration_cost_ns = 5000000
kernel.sched_min_granularity_ns = 1000000
kernel.sched_wakeup_granularity_ns = 500000
kernel.nmi_watchdog=0
EOF
    
    # Apply sysctl changes
    sysctl -p
    
    # Disable mitigations for better performance (security tradeoff)
    echo 'GRUB_CMDLINE_LINUX="$GRUB_CMDLINE_LINUX mitigations=off"' >> /etc/default/grub
    
    # Configure CPU isolation for nanosecond latency
    echo 'GRUB_CMDLINE_LINUX="$GRUB_CMDLINE_LINUX isolcpus=1-3 rcu_nocbs=1-3 nohz_full=1-3"' >> /etc/default/grub
    
    # Set CPU frequency governor to performance for all CPUs
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo performance > $cpu 2>/dev/null || true
    done
    
    # Disable CPU idle states for better latency
    echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
    
    # Disable hyperthreading if available
    echo off > /sys/devices/system/cpu/smt/control 2>/dev/null || true
    
    # Disable watchdog
    echo 0 > /proc/sys/kernel/watchdog
    
    # Increase priority of real-time processes
    echo -n 99 > /proc/sys/kernel/sched_rt_priority_max
    
    log "Real-time optimizations applied successfully"
}

# Verification function
verify_installation() {
    log "Running comprehensive verification..."
    
    echo "=== Real-Time System Verification ==="
    
    # 1. Kernel checks
    echo -n "Kernel: "
    if uname -a | grep -q "EVL"; then
        echo "OK (EVL detected)"
    else
        echo "FAIL"
        warn "EVL kernel not detected. You may need to reboot."
    fi
    
    # 2. Core configurations
    echo -n "EVL Core: "
    if grep -q "CONFIG_EVL=y" /boot/config-$(uname -r) 2>/dev/null; then
        echo "OK"
    else
        echo "FAIL"
    fi
    
    echo -n "PREEMPT_RT: "
    if grep -q "CONFIG_PREEMPT_RT=y" /boot/config-$(uname -r) 2>/dev/null; then
        echo "OK"
    else
        echo "FAIL"
    fi
    
    # 3. System configuration
    echo -e "\nSystem Checks:"
    echo -n "CPU Isolation: "
    if grep -q "isolcpus" /proc/cmdline; then
        echo "OK"
    else
        echo "MISSING"
    fi
    
    echo -n "CPU Frequency: "
    if cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | uniq | grep -q performance; then
        echo "OK"
    else
        echo "NOT PERFORMANCE"
    fi
    
    echo -n "Hyperthreading: "
    if cat /sys/devices/system/cpu/smt/active 2>/dev/null | grep -q 0; then
        echo "DISABLED"
    else
        echo "ENABLED (WARNING)"
    fi
    
    # 4. Check if Xenomai 4 is available
    echo -e "\nXenomai 4 Checks:"
    if command -v xeno-config >/dev/null 2>&1; then
        echo "Xenomai 4: OK"
        echo "Version: $(xeno-config --version 2>/dev/null || echo 'Unknown')"
    else
        echo "Xenomai 4: NOT FOUND (may need to source /etc/profile)"
    fi
    
    echo "=== Verification Complete ==="
}

# Main installation function
main() {
    log "Starting Xenomai 4 installation..."
    log "This installation will take 60-120 minutes depending on your system"
    
    # Check prerequisites
    check_root
    check_requirements
    
    # Install all components
    install_dependencies
    build_evl_kernel
    install_libevl
    install_xenomai4
    configure_xenomai4
    optimize_system
    
    # Update GRUB one final time
    update-grub
    
    log "Installation completed successfully!"
    log "System will reboot in 10 seconds to load the EVL-patched kernel..."
    log "After reboot, run: source /etc/profile && verify_installation"
    
    # Ask user if they want to reboot now
    read -p "Reboot now? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        reboot
    else
        log "Please reboot manually when ready to complete the installation"
    fi
}

# Cleanup function
cleanup() {
    log "Cleaning up build files..."
    rm -rf /tmp/xenomai4-build
    rm -rf /tmp/libevl-build
    rm -rf /tmp/linux-evl-build
    log "Cleanup completed"
}

# Handle script interruption
trap 'error "Installation interrupted by user"' INT TERM

# Run main function
main "$@" 
