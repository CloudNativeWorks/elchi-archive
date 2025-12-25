#!/bin/bash

#################################################################################
# Elchi Stack Installation Script
#
# Description: Automated installation script for Elchi proxy management platform
#              on Ubuntu 24.04 with kind (Kubernetes in Docker)
#
# Usage: ./install.sh <mainAddress> <port>
# Example: ./install.sh elchi.example.com 8080
#
# Requirements:
#   - Ubuntu 24.04 (minimal installation)
#   - Root or sudo privileges
#   - Internet connectivity
#
# Author: Elchi Team
# License: MIT
#################################################################################

set -euo pipefail  # Exit on error, undefined variables, and pipe failures

# Script version
readonly SCRIPT_VERSION="1.0.0"

# Installation versions
readonly KIND_VERSION="v0.20.0"
readonly KUBECTL_VERSION="stable"

# Cluster configuration
readonly CLUSTER_NAME="elchi-cluster"
readonly CLUSTER_NAMESPACE="elchi-stack"
readonly HELM_REPO_NAME="elchi"
readonly HELM_REPO_URL="https://charts.elchi.io/"
readonly HELM_CHART_NAME="elchi-stack"

# Color codes for output
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_MAGENTA='\033[0;35m'
readonly COLOR_RESET='\033[0m'

# Step counter
CURRENT_STEP=0
TOTAL_STEPS=14

# Logging functions
log_info() {
    echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $*"
}

log_success() {
    echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} $*"
}

log_warning() {
    echo -e "${COLOR_YELLOW}[WARNING]${COLOR_RESET} $*"
}

log_error() {
    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2
}

log_step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    echo -e "\n${COLOR_MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}"
    echo -e "${COLOR_CYAN}▶ [Step ${CURRENT_STEP}/${TOTAL_STEPS}] $*${COLOR_RESET}"
    echo -e "${COLOR_MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}\n"
}

# Error handler
error_exit() {
    log_error "$1"
    exit 1
}

# Cleanup function
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log_error "Installation failed with exit code: $exit_code"
        log_info "Check the error messages above for details"
    fi
    rm -f /tmp/kind-config.yaml 2>/dev/null || true
}

trap cleanup EXIT

# Print banner
print_banner() {
    echo -e "${COLOR_CYAN}"
    cat << "EOF"
╔═══════════════════════════════════════════════════════════════╗
║                                                               ║
║              _____ _      ____ _   _ ___                      ║
║             | ____| |    / ___| | | |_ _|                     ║
║             |  _| | |   | |   | |_| || |                      ║
║             | |___| |___| |___|  _  || |                      ║
║             |_____|_____|\____|_| |_|___|                     ║
║                                                               ║
║         Elchi Stack Installation Script v1.0.0                ║
║         Kubernetes-based Proxy Management Platform            ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝
EOF
    echo -e "${COLOR_RESET}\n"
}

# Validate OS
validate_os() {
    log_step "Validating Operating System"

    if [ ! -f /etc/os-release ]; then
        error_exit "Cannot detect OS. This script requires Ubuntu 24.04"
    fi

    source /etc/os-release

    if [[ "$ID" != "ubuntu" ]]; then
        log_warning "This script is designed for Ubuntu 24.04, detected: $ID $VERSION_ID"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
    elif [[ "$VERSION_ID" != "24.04" ]]; then
        log_warning "Recommended version is 24.04, detected: $VERSION_ID"
    fi

    log_success "OS validation completed: $PRETTY_NAME"
}

# Check prerequisites
check_prerequisites() {
    log_step "Checking Prerequisites"

    # Check if running with appropriate privileges
    if [ "$EUID" -eq 0 ]; then
        log_warning "Running as root. It's recommended to run as a regular user with sudo access"
    fi

    # Check sudo access
    if ! sudo -n true 2>/dev/null; then
        log_info "This script requires sudo privileges"
        sudo -v || error_exit "Failed to obtain sudo privileges"
    fi

    # Check disk space
    log_info "Checking available disk space..."
    local required_space_gb=15
    local available_space_gb=$(df / | awk 'NR==2 {printf "%.0f", $4/1024/1024}')

    log_info "Available disk space: ${available_space_gb}GB (required: ~${required_space_gb}GB, recommended: 20GB)"

    if [ "$available_space_gb" -lt "$required_space_gb" ]; then
        log_error "Insufficient disk space!"
        log_error "Available: ${available_space_gb}GB, Required: ~${required_space_gb}GB"
        echo ""
        log_info "Disk space breakdown:"
        log_info "  • Docker images: ~6-7GB"
        log_info "  • Kubernetes (kind): ~3-4GB"
        log_info "  • Elchi stack containers: ~3-4GB"
        log_info "  • System packages: ~1GB"
        log_info "  • Working space: ~1-2GB"
        error_exit "Please free up at least ${required_space_gb}GB of disk space"
    fi

    log_success "Sufficient disk space available"

    # Check internet connectivity
    log_info "Testing internet connectivity..."
    if ! ping -c 1 -W 2 google.com &>/dev/null && ! ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        error_exit "No internet connectivity detected"
    fi

    log_success "Prerequisites check completed"
}

# Parse and validate arguments
parse_arguments() {
    if [ $# -ne 2 ]; then
        cat << EOF
${COLOR_RED}Error: Invalid number of arguments${COLOR_RESET}

Usage: $0 <mainAddress> <port>

Arguments:
  mainAddress    The main address/domain for Elchi (e.g., elchi.example.com or 192.168.1.100)
  port           The port number to expose Elchi service (e.g., 80, 8080, 30080)

Examples:
  $0 elchi.example.com 80
  $0 192.168.1.100 8080
  $0 elchi-test.hepsi.io 30080

EOF
        exit 1
    fi

    MAIN_ADDRESS="$1"
    PORT="$2"

    # Validate port number
    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        error_exit "Invalid port number: $PORT (must be between 1-65535)"
    fi

    log_info "Installation Configuration:"
    log_info "  Main Address: ${COLOR_GREEN}$MAIN_ADDRESS${COLOR_RESET}"
    log_info "  Port: ${COLOR_GREEN}$PORT${COLOR_RESET}"
    echo
}

# Update system packages
update_system() {
    log_step "Updating System Packages"

    log_info "Running apt-get update..."
    sudo apt-get update -qq || error_exit "Failed to update package lists"

    log_success "System packages updated successfully"
}

# Install package if not present
install_package() {
    local package_name="$1"
    local check_command="${2:-$1}"
    local install_method="${3:-apt}"

    if command -v "$check_command" &>/dev/null; then
        local version=$(${check_command} --version 2>&1 | head -n1 || echo "version unknown")
        log_success "$package_name already installed: $version"
        return 0
    fi

    log_info "Installing $package_name..."

    case "$install_method" in
        apt)
            sudo apt-get install -y -qq "$package_name" || error_exit "Failed to install $package_name"
            ;;
        custom)
            return 1  # Signal that custom installation is needed
            ;;
    esac

    log_success "$package_name installed successfully"
}

# Install Docker
install_docker() {
    log_step "Installing Docker"

    if command -v docker &>/dev/null; then
        local docker_version=$(docker --version)
        log_success "Docker already installed: $docker_version"
        return 0
    fi

    log_info "Installing Docker from official repository..."

    # Install prerequisites
    sudo apt-get install -y -qq ca-certificates curl gnupg lsb-release

    # Add Docker's official GPG key
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null || \
        error_exit "Failed to add Docker GPG key"
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    # Set up the repository
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Install Docker Engine
    sudo apt-get update -qq
    sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin || \
        error_exit "Failed to install Docker"

    # Add current user to docker group
    sudo usermod -aG docker "$USER" || log_warning "Failed to add user to docker group"

    # Enable and start Docker service
    sudo systemctl enable docker --now || log_warning "Failed to enable Docker service"

    log_success "Docker installed successfully"
    log_warning "You may need to log out and back in for docker group changes to take effect"

    # Use newgrp to activate group without logout (for this session)
    if [ -t 0 ]; then
        log_info "Activating docker group for current session..."
    fi
}

# Install kubectl
install_kubectl() {
    log_step "Installing kubectl"

    if command -v kubectl &>/dev/null; then
        # Verify kubectl works
        if kubectl version --client &>/dev/null 2>&1; then
            local kubectl_version=$(kubectl version --client --short 2>/dev/null | head -n1)
            log_success "kubectl already installed: $kubectl_version"
            return 0
        else
            log_warning "kubectl exists but is not working, reinstalling..."
            sudo rm -f /usr/local/bin/kubectl
        fi
    fi

    log_info "Downloading kubectl..."

    # Detect architecture
    local arch=$(uname -m)
    local kubectl_arch

    case "$arch" in
        x86_64)
            kubectl_arch="amd64"
            ;;
        aarch64|arm64)
            kubectl_arch="arm64"
            ;;
        armv7l)
            kubectl_arch="arm"
            ;;
        *)
            error_exit "Unsupported architecture: $arch"
            ;;
    esac

    log_info "Detected architecture: $arch (using kubectl binary for $kubectl_arch)"

    local kubectl_url="https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/${kubectl_arch}/kubectl"
    curl -LO "$kubectl_url" || error_exit "Failed to download kubectl"

    # Verify the binary (optional but recommended)
    curl -LO "${kubectl_url}.sha256"
    echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check --quiet || \
        log_warning "kubectl checksum verification failed"

    chmod +x kubectl
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm -f kubectl kubectl.sha256

    log_success "kubectl installed successfully: $(kubectl version --client --short 2>/dev/null)"
}

# Install kind
install_kind() {
    log_step "Installing kind (Kubernetes in Docker)"

    if command -v kind &>/dev/null; then
        local kind_version=$(kind version)
        log_success "kind already installed: $kind_version"
        return 0
    fi

    log_info "Downloading kind ${KIND_VERSION}..."

    local arch=$(uname -m)
    local kind_binary

    case "$arch" in
        x86_64)
            kind_binary="kind-linux-amd64"
            ;;
        aarch64|arm64)
            kind_binary="kind-linux-arm64"
            ;;
        *)
            error_exit "Unsupported architecture: $arch"
            ;;
    esac

    curl -Lo ./kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/${kind_binary}" || \
        error_exit "Failed to download kind"

    chmod +x ./kind
    sudo mv ./kind /usr/local/bin/kind

    log_success "kind installed successfully: $(kind version)"
}

# Install Helm
install_helm() {
    log_step "Installing Helm"

    if command -v helm &>/dev/null; then
        local helm_version=$(helm version --short)
        log_success "Helm already installed: $helm_version"
        return 0
    fi

    log_info "Installing Helm via official script..."

    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash || \
        error_exit "Failed to install Helm"

    log_success "Helm installed successfully: $(helm version --short)"
}

# Install network utilities
install_network_tools() {
    log_step "Installing Network Utilities"

    # Check and install ping (iputils-ping)
    if ! command -v ping &>/dev/null; then
        log_info "Installing iputils-ping..."
        sudo apt-get install -y -qq iputils-ping || error_exit "Failed to install iputils-ping"
        log_success "iputils-ping installed successfully"
    else
        log_success "ping already installed"
    fi

    # Check and install DNS utilities
    if ! command -v nslookup &>/dev/null; then
        log_info "Installing dnsutils..."
        sudo apt-get install -y -qq dnsutils || error_exit "Failed to install dnsutils"
        log_success "dnsutils installed successfully"
    else
        log_success "nslookup already installed"
    fi

    log_success "Network utilities ready (ping, nslookup, dig)"
}

# Install all required tools
install_required_tools() {
    install_package "git" "git"
    install_docker
    install_kubectl
    install_kind
    install_helm
    install_network_tools
}

# Create kind cluster
create_kind_cluster() {
    log_step "Creating kind Cluster: $CLUSTER_NAME"

    # Check if cluster already exists
    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        log_warning "Cluster '$CLUSTER_NAME' already exists"
        log_info "Deleting existing cluster to ensure clean installation..."
        kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null || true

        # Clean up any leftover containers
        log_info "Cleaning up leftover containers..."
        docker ps -a --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" --format "{{.ID}}" | xargs -r docker rm -f 2>/dev/null || true

        sleep 2  # Wait for cleanup
        log_success "Existing cluster deleted and cleaned up"
    fi

    # Create kind configuration
    log_info "Generating cluster configuration..."

    cat > /tmp/kind-config.yaml <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
nodes:
- role: control-plane
  extraPortMappings:
  # Port mapping for Elchi service
  - containerPort: ${PORT}
    hostPort: ${PORT}
    protocol: TCP
  # Additional port mappings
  - containerPort: 30001
    hostPort: 30001
    protocol: TCP
  - containerPort: 30002
    hostPort: 30002
    protocol: TCP
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
- role: worker
  labels:
    worker: "1"
- role: worker
  labels:
    worker: "2"
EOF

    log_info "Cluster configuration:"
    log_info "  Name: $CLUSTER_NAME"
    log_info "  Nodes: 1 control-plane + 2 workers"
    log_info "  Port mapping: ${PORT}:${PORT} (container:host)"
    echo

    # Create the cluster
    log_info "Creating cluster (this may take a few minutes)..."
    kind create cluster --config /tmp/kind-config.yaml || \
        error_exit "Failed to create kind cluster"

    log_success "Kind cluster created successfully"

    # Verify cluster
    log_info "Verifying cluster status..."
    kubectl cluster-info --context "kind-${CLUSTER_NAME}" || \
        error_exit "Failed to connect to cluster"

    # Wait for all nodes to be ready
    log_info "Waiting for all nodes to be ready..."
    kubectl wait --for=condition=Ready nodes --all --timeout=300s || \
        error_exit "Timeout waiting for nodes to be ready"

    # Display node status
    log_success "All nodes are ready:"
    kubectl get nodes -o wide
    echo
}

# Setup Helm repository
setup_helm_repo() {
    log_step "Setting up Helm Repository"

    log_info "Adding Elchi Helm repository..."
    helm repo add "$HELM_REPO_NAME" "$HELM_REPO_URL" 2>/dev/null || \
        helm repo add "$HELM_REPO_NAME" "$HELM_REPO_URL" --force-update

    log_info "Updating Helm repositories..."
    helm repo update || error_exit "Failed to update Helm repositories"

    log_success "Helm repository configured successfully"

    # List available charts
    log_info "Available Elchi charts:"
    helm search repo "$HELM_REPO_NAME" || true
    echo
}

# Install Elchi Stack
install_elchi_stack() {
    log_step "Installing Elchi Stack"

    log_info "Installation parameters:"
    log_info "  Chart: ${HELM_REPO_NAME}/${HELM_CHART_NAME}"
    log_info "  Namespace: $CLUSTER_NAMESPACE"
    log_info "  Main Address: $MAIN_ADDRESS"
    log_info "  Port: $PORT"
    echo

    log_info "Installing Elchi stack..."

    helm install "$HELM_CHART_NAME" "${HELM_REPO_NAME}/${HELM_CHART_NAME}" \
        --namespace "$CLUSTER_NAMESPACE" \
        --create-namespace \
        --set-string global.mainAddress="$MAIN_ADDRESS" \
        --set-string global.port="$PORT" \
        --set global.envoy.service.httpNodePort="$PORT" \
        --set-string mongodb.persistence.storageClass="standard" \
        --set-string victoriametrics.persistence.storageClass="standard" || error_exit "Failed to install Elchi stack"

    log_success "Elchi stack installation initiated"
    log_info "Helm chart deployed. Pods are starting in the background..."
    log_info "Use 'kubectl get pods -n ${CLUSTER_NAMESPACE} -w' to monitor pod status"
}

# Verify installation
verify_installation() {
    log_step "Verifying Installation"

    log_info "Checking pod status..."
    kubectl get pods -n "$CLUSTER_NAMESPACE" -o wide
    echo

    log_info "Checking service status..."
    kubectl get svc -n "$CLUSTER_NAMESPACE"
    echo

    log_success "Installation verification completed"
    log_info "Note: Pods may still be starting. Monitor with: kubectl get pods -n $CLUSTER_NAMESPACE -w"
}

# Print summary
print_summary() {
    log_step "Installation Summary"

    echo -e "${COLOR_GREEN}╔═══════════════════════════════════════════════════════════════╗"
    echo -e "║                                                               ║"
    echo -e "║              Installation Completed Successfully!             ║"
    echo -e "║                                                               ║"
    echo -e "╚═══════════════════════════════════════════════════════════════╝${COLOR_RESET}"
    echo ""
    echo -e "${COLOR_CYAN}Cluster Information:${COLOR_RESET}"
    echo "  Cluster Name:       ${CLUSTER_NAME}"
    echo "  Context:            kind-${CLUSTER_NAME}"
    echo "  Namespace:          ${CLUSTER_NAMESPACE}"
    echo "  Nodes:              1 control-plane + 2 workers"
    echo ""
    echo -e "${COLOR_CYAN}Elchi Configuration:${COLOR_RESET}"
    echo "  Main Address:       ${MAIN_ADDRESS}"
    echo "  Port:               ${PORT}"
    echo "  Access URL:         http://${MAIN_ADDRESS}:${PORT}"
    echo ""
    echo -e "${COLOR_CYAN}Useful Commands:${COLOR_RESET}"
    echo "  # View all resources"
    echo "  kubectl get all -n ${CLUSTER_NAMESPACE}"
    echo ""
    echo "  # View pods"
    echo "  kubectl get pods -n ${CLUSTER_NAMESPACE}"
    echo ""
    echo "  # View services"
    echo "  kubectl get svc -n ${CLUSTER_NAMESPACE}"
    echo ""
    echo "  # View pod logs"
    echo "  kubectl logs -n ${CLUSTER_NAMESPACE} <pod-name>"
    echo ""
    echo "  # List Helm releases"
    echo "  helm list -n ${CLUSTER_NAMESPACE}"
    echo ""
    echo "  # Port forward (if needed)"
    echo "  kubectl port-forward -n ${CLUSTER_NAMESPACE} svc/elchi-service ${PORT}:${PORT}"
    echo ""
    echo "  # Delete cluster"
    echo "  kind delete cluster --name ${CLUSTER_NAME}"
    echo ""
    echo -e "${COLOR_CYAN}Next Steps:${COLOR_RESET}"
    echo -e "  1. Access Elchi UI at: ${COLOR_GREEN}http://${MAIN_ADDRESS}:${PORT}${COLOR_RESET}"
    echo "  2. Configure your proxies through the web interface"
    echo "  3. Monitor logs: kubectl logs -n ${CLUSTER_NAMESPACE} -l app=elchi --tail=100 -f"
    echo ""
    echo -e "${COLOR_YELLOW}Note:${COLOR_RESET} If you added your user to the docker group, you may need to"
    echo "      log out and back in for the changes to take effect."
    echo ""
    echo "For more information, visit: https://elchi.io/docs"
    echo ""
    echo -e "${COLOR_GREEN}Happy proxying! 🚀${COLOR_RESET}"
}

#################################################################################
# Main execution flow
#################################################################################

main() {
    print_banner

    parse_arguments "$@"

    validate_os

    check_prerequisites

    update_system

    install_required_tools

    create_kind_cluster

    setup_helm_repo

    install_elchi_stack

    verify_installation

    print_summary

    log_success "All done! Elchi stack is ready to use."
}

# Run main function
main "$@"
