#!/usr/bin/env bash
# install_shadowsocks.sh
# Installs shadowsocks-rust v1.24.0 (x86_64-unknown-linux-gnu) from a pre-downloaded .tar.xz package.
# Also enables BBR TCP congestion control and tunes network buffers.
# Usage:
#   ./install_shadowsocks.sh                          # auto-download from GitHub
#   ./install_shadowsocks.sh /path/to/package.tar.xz  # use a local package

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────
SS_VERSION="1.24.0"
SS_ARCH="x86_64-unknown-linux-gnu"
SS_PACKAGE="shadowsocks-v${SS_VERSION}.${SS_ARCH}.tar.xz"
SS_DOWNLOAD_URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${SS_VERSION}/${SS_PACKAGE}"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/shadowsocks-rust"
SERVICE_NAME="shadowsocks-rust"

# Binaries included in the package
BINARIES=(ssserver sslocal ssmanager ssurl ssservice)

# Global temp dir — must be global so the EXIT trap can access it
# even when the script is piped via curl | bash
TMP_DIR=""

# ── Helpers ────────────────────────────────────────────────────────────────────
info()    { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
success() { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()    { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error()   { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

require_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)."
    fi
}

# Generate a cryptographically random password (base64, 22 chars)
gen_password() {
    if command -v openssl &>/dev/null; then
        openssl rand -base64 16 | tr -d '\n/+=' | head -c 22
    else
        # Fallback: /dev/urandom + tr
        tr -dc 'A-Za-z0-9!@#%^&*' </dev/urandom 2>/dev/null | head -c 22
    fi
}

# Enable BBR TCP congestion control and tune network buffers
setup_bbr() {
    info "Configuring BBR TCP congestion control..."

    local kernel_ver
    kernel_ver=$(uname -r | cut -d. -f1-2 | tr -d '.')
    # BBR requires kernel >= 4.9
    if [[ "$kernel_ver" -lt 49 ]]; then
        warn "Kernel $(uname -r) is older than 4.9; BBR may not be available. Skipping."
        return
    fi

    local sysctl_conf="/etc/sysctl.d/99-shadowsocks-bbr.conf"
    cat > "$sysctl_conf" <<'SYSCTL'
# BBR congestion control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Network buffer tuning
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_mtu_probing = 1
SYSCTL

    sysctl -p "$sysctl_conf" &>/dev/null || warn "sysctl apply failed; reboot to take effect."

    # Verify BBR is active
    local current_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [[ "$current_cc" == "bbr" ]]; then
        success "BBR enabled (congestion control: bbr, qdisc: fq)"
    else
        warn "BBR not active yet (current: $current_cc). A reboot may be required."
    fi
}

check_arch() {
    local arch
    arch=$(uname -m)
    if [[ "$arch" != "x86_64" ]]; then
        error "This package targets x86_64, but the current machine is $arch."
    fi
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
    require_root
    check_arch

    local package_path="${1:-}"
    TMP_DIR=$(mktemp -d)
    trap '[[ -n "$TMP_DIR" ]] && rm -rf "$TMP_DIR"' EXIT

    # Step 1: Obtain the package
    if [[ -n "$package_path" ]]; then
        if [[ ! -f "$package_path" ]]; then
            error "Specified package not found: $package_path"
        fi
        info "Using local package: $package_path"
        cp "$package_path" "$TMP_DIR/$SS_PACKAGE"
    else
        info "Downloading $SS_PACKAGE from GitHub..."
        if command -v curl &>/dev/null; then
            curl -fSL --progress-bar "$SS_DOWNLOAD_URL" -o "$TMP_DIR/$SS_PACKAGE"
        elif command -v wget &>/dev/null; then
            wget -q --show-progress "$SS_DOWNLOAD_URL" -O "$TMP_DIR/$SS_PACKAGE"
        else
            error "Neither curl nor wget is available. Install one and retry."
        fi
        success "Download complete."
    fi

    # Step 2: Extract
    info "Extracting package..."
    tar -xJf "$TMP_DIR/$SS_PACKAGE" -C "$TMP_DIR"
    success "Extraction complete."

    # Step 3: Install binaries
    info "Installing binaries to $INSTALL_DIR ..."
    for bin in "${BINARIES[@]}"; do
        if [[ -f "$TMP_DIR/$bin" ]]; then
            install -m 755 "$TMP_DIR/$bin" "$INSTALL_DIR/$bin"
            success "Installed: $INSTALL_DIR/$bin"
        else
            warn "Binary not found in package, skipping: $bin"
        fi
    done

    # Step 4: Create config directory
    if [[ ! -d "$CONFIG_DIR" ]]; then
        mkdir -p "$CONFIG_DIR"
        info "Created config directory: $CONFIG_DIR"
    fi

    # Step 5: Create a default config if none exists
    local config_file="$CONFIG_DIR/config.json"
    if [[ ! -f "$config_file" ]]; then
        info "Generating random password..."
        local ss_password
        ss_password=$(gen_password)
        info "Creating default server config at $config_file ..."
        cat > "$config_file" <<EOF
{
    "server": "0.0.0.0",
    "server_port": 8388,
    "password": "${ss_password}",
    "method": "aes-256-gcm",
    "timeout": 300,
    "fast_open": false,
    "mode": "tcp_and_udp"
}
EOF
        chmod 600 "$config_file"
        success "Config written with randomly generated password."
        echo ""
        echo "  ┌─────────────────────────────────────────┐"
        echo "  │  Server Port : 8388                     │"
        printf  "  │  Password    : %-25s │\n" "$ss_password"
        echo "  │  Method      : aes-256-gcm              │"
        echo "  └─────────────────────────────────────────┘"
        echo ""
    else
        info "Config already exists, skipping: $config_file"
    fi

    # Step 5.5: Enable BBR
    setup_bbr

    # Step 6: Create a systemd service (if systemd is available)
    if command -v systemctl &>/dev/null; then
        local service_file="/etc/systemd/system/${SERVICE_NAME}.service"
        if [[ ! -f "$service_file" ]]; then
            info "Creating systemd service: $service_file"
            cat > "$service_file" <<EOF
[Unit]
Description=Shadowsocks-Rust Server Service
After=network.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/ssserver -c $config_file
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            success "Systemd service created: $SERVICE_NAME"
            info "To enable and start: systemctl enable --now $SERVICE_NAME"
        else
            info "Systemd service already exists, skipping base service creation."
        fi

        info "Configuring service logging to debug connections..."
        local override_dir="/etc/systemd/system/${SERVICE_NAME}.service.d"
        mkdir -p "$override_dir"
        cat > "$override_dir/override.conf" <<'OVERRIDE'
[Service]
Environment="RUST_LOG=warn,shadowsocks=debug"
OVERRIDE

        systemctl daemon-reload
        # 尝试重启服务以加载新的二进制或新日志配置（如果服务本来没在运行，try-restart 什么也不做，不会报错）
        systemctl try-restart "$SERVICE_NAME" || true
    else
        warn "systemd not found. You will need to start ssserver manually."
        info "Example: $INSTALL_DIR/ssserver -c $config_file"
    fi

    # Step 7: Create a handy log viewer command
    local sslog_bin="$INSTALL_DIR/sslog"
    info "Creating handy log viewer wrapper at $sslog_bin ..."
    cat > "$sslog_bin" <<'EOF'
#!/usr/bin/env bash
# Fast, clean log viewer for shadowsocks-rust
sudo journalctl -u shadowsocks-rust -f --output=cat \
  | grep --line-buffered "tunnel\|listening\|exiting" \
  | sed 's/ with ConnectOpts{.*//; s/ with ConnectOpts {.*//'
EOF
    chmod +x "$sslog_bin"

    echo ""
    success "shadowsocks-rust v${SS_VERSION} installation complete!"
    echo ""
    echo "  Config  : $config_file"
    echo "  Binaries: $INSTALL_DIR/{$(IFS=,; echo "${BINARIES[*]}")}"
    echo "  Logs CMD: sslog"
    if command -v systemctl &>/dev/null; then
        echo "  Service : systemctl enable --now $SERVICE_NAME"
    fi
    echo ""
}

main "$@"
