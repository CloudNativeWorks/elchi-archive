#!/bin/bash

#################################################################################
# Elchi Stack Uninstallation Script
#
# Description: Removes Elchi installation including kind cluster, kubectl, and Helm
#              Preserves Docker and other system packages
#
# Usage: ./uninstall.sh
#
# Author: Elchi Team
# License: MIT
#################################################################################

set -euo pipefail  # Exit on error, undefined variables, and pipe failures

# Cluster configuration (same as install.sh)
readonly CLUSTER_NAME="elchi-cluster"
readonly CLUSTER_NAMESPACE="elchi-stack"

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
TOTAL_STEPS=5

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

# Print banner
print_banner() {
    echo -e "${COLOR_RED}"
    cat << "EOF"
╔═══════════════════════════════════════════════════════════════╗
║                                                               ║
║              _____ _      ____ _   _ ___                      ║
║             | ____| |    / ___| | | |_ _|                     ║
║             |  _| | |   | |   | |_| || |                      ║
║             | |___| |___| |___|  _  || |                      ║
║             |_____|_____|\____|_| |_|___|                     ║
║                                                               ║
║         Elchi Stack Uninstallation Script                     ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝
EOF
    echo -e "${COLOR_RESET}\n"
}

# Confirm uninstallation
ASSUME_YES=${ELCHI_ASSUME_YES:-0}
while [ "$#" -gt 0 ]; do
    case "$1" in
        -y|--yes) ASSUME_YES=1 ;;
        -h|--help)
            printf 'Usage: %s [--yes]\n\n  --yes, -y   do not prompt (also: ELCHI_ASSUME_YES=1)\n' "$0"
            exit 0
            ;;
        *) printf 'unknown flag: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

confirm_uninstall() {
    echo -e "${COLOR_YELLOW}WARNING: This will remove the following:${COLOR_RESET}"
    echo "  • kind cluster: $CLUSTER_NAME"
    echo "  • kubectl binary"
    echo "  • Helm binary"
    echo "  • kind binary"
    echo "  • Docker images used by Elchi"
    echo ""
    echo -e "${COLOR_GREEN}Docker itself and other system packages will be preserved.${COLOR_RESET}"
    echo ""

    # Scripted teardown: --yes/-y, or ELCHI_ASSUME_YES=1. Without one of those
    # this used to run `read` against a closed stdin in any non-TTY context
    # (CI, nohup, `curl … | bash`), print the banner and exit 1 having done
    # nothing — with no flag to reach for, since the script parsed no
    # arguments at all. The other two installers both take --yes-i-mean-it.
    if [ "$ASSUME_YES" = "1" ]; then
        log_info "proceeding without prompt (--yes)"
        echo
        return 0
    fi
    if [ ! -t 0 ]; then
        log_error "no terminal to confirm on — re-run with --yes (or ELCHI_ASSUME_YES=1) to uninstall non-interactively"
        exit 1
    fi

    read -p "Are you sure you want to continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Uninstallation cancelled by user"
        exit 0
    fi
    echo
}

# Delete kind cluster
delete_kind_cluster() {
    log_step "Deleting kind Cluster: $CLUSTER_NAME"

    # Check if kind exists
    if ! command -v kind &>/dev/null; then
        log_warning "kind is not installed, skipping cluster deletion"
        return 0
    fi

    # Check if cluster exists
    if ! kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        log_warning "Cluster '$CLUSTER_NAME' does not exist, skipping deletion"
        return 0
    fi

    log_info "Deleting cluster '$CLUSTER_NAME'..."
    kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null || true

    # Clean up any leftover containers
    if command -v docker &>/dev/null; then
        log_info "Cleaning up leftover containers..."
        docker ps -a --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" --format "{{.ID}}" | \
            xargs -r docker rm -f 2>/dev/null || true
    fi

    log_success "Cluster deleted successfully"
}

# Remove kubectl
remove_kubectl() {
    log_step "Removing kubectl"

    if [ ! -f /usr/local/bin/kubectl ]; then
        log_warning "kubectl is not installed at /usr/local/bin/kubectl, skipping"
        return 0
    fi

    log_info "Removing kubectl binary..."
    sudo rm -f /usr/local/bin/kubectl

    log_success "kubectl removed successfully"
}

# Remove Helm
remove_helm() {
    log_step "Removing Helm"

    if ! command -v helm &>/dev/null; then
        log_warning "Helm is not installed, skipping"
        return 0
    fi

    log_info "Removing Helm binary..."
    sudo rm -f /usr/local/bin/helm

    # Remove Helm cache and config (optional)
    log_info "Cleaning up Helm cache and configuration..."
    rm -rf ~/.cache/helm 2>/dev/null || true
    rm -rf ~/.config/helm 2>/dev/null || true
    rm -rf ~/.local/share/helm 2>/dev/null || true

    log_success "Helm removed successfully"
}

# Remove kind
remove_kind() {
    log_step "Removing kind"

    if ! command -v kind &>/dev/null; then
        log_warning "kind is not installed, skipping"
        return 0
    fi

    log_info "Removing kind binary..."
    sudo rm -f /usr/local/bin/kind

    log_success "kind removed successfully"
}

# Clean up Docker images
cleanup_docker_images() {
    log_step "Cleaning up Docker Images"

    if ! command -v docker &>/dev/null; then
        log_warning "Docker is not installed, skipping image cleanup"
        return 0
    fi

    log_info "Removing kind node images..."
    docker images | grep 'kindest/node' | awk '{print $3}' | xargs -r docker rmi -f 2>/dev/null || true

    log_info "Removing Elchi-related images..."
    docker images | grep -E 'elchi|mongo|victoriametrics|envoyproxy' | awk '{print $3}' | xargs -r docker rmi -f 2>/dev/null || true

    log_info "Pruning dangling images..."
    docker image prune -f 2>/dev/null || true

    log_success "Docker images cleaned up successfully"
}

# Print summary
print_summary() {
    echo -e "\n${COLOR_GREEN}╔═══════════════════════════════════════════════════════════════╗"
    echo -e "║                                                               ║"
    echo -e "║            Uninstallation Completed Successfully!             ║"
    echo -e "║                                                               ║"
    echo -e "╚═══════════════════════════════════════════════════════════════╝${COLOR_RESET}"
    echo ""
    echo -e "${COLOR_CYAN}Removed Components:${COLOR_RESET}"
    echo "  ✓ kind cluster: $CLUSTER_NAME"
    echo "  ✓ kubectl binary"
    echo "  ✓ Helm binary"
    echo "  ✓ kind binary"
    echo "  ✓ Docker images (Elchi, kind, mongo, victoriametrics, envoy)"
    echo ""
    echo -e "${COLOR_CYAN}Preserved Components:${COLOR_RESET}"
    echo "  • Docker itself"
    echo "  • Git"
    echo "  • Network utilities (ping, nslookup)"
    echo "  • System packages"
    echo ""
    echo -e "${COLOR_GREEN}Thank you for using Elchi! 👋${COLOR_RESET}"
}

#################################################################################
# Main execution flow
#################################################################################

main() {
    print_banner

    confirm_uninstall

    delete_kind_cluster

    cleanup_docker_images

    remove_kubectl

    remove_helm

    remove_kind

    print_summary

    log_success "All done! Elchi has been uninstalled."
}

# Run main function
main "$@"
