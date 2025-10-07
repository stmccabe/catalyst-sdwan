#!/usr/bin/env bash
# ============================================
# deploy_sdwan.sh - Optimized Deployment Script
# ============================================

set -euo pipefail
IFS=$'\n\t'

# Script metadata
readonly SCRIPT_VERSION="2.0.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
readonly TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

# Directories
readonly LOG_DIR="${PROJECT_ROOT}/logs"
readonly REPORT_DIR="${PROJECT_ROOT}/reports"
readonly BACKUP_DIR="${PROJECT_ROOT}/backup"
readonly STATE_DIR="${PROJECT_ROOT}/.state"

# Files
readonly LOG_FILE="${LOG_DIR}/deployment_${TIMESTAMP}.log"
readonly STATE_FILE="${STATE_DIR}/deployment_state.json"
readonly PID_FILE="${STATE_DIR}/deployment.pid"

# Colors and formatting
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# Deployment configuration
DEPLOY_MODE="${DEPLOY_MODE:-full}"
SKIP_VALIDATION="${SKIP_VALIDATION:-false}"
FORCE_DEPLOY="${FORCE_DEPLOY:-false}"
DRY_RUN="${DRY_RUN:-false}"
PARALLEL="${PARALLEL:-true}"
VERBOSE="${VERBOSE:-false}"

# ============================================
# UTILITY FUNCTIONS
# ============================================

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case "$level" in
        INFO)  echo -e "${BLUE}[INFO]${NC} ${message}" | tee -a "$LOG_FILE" ;;
        SUCCESS) echo -e "${GREEN}[✓]${NC} ${message}" | tee -a "$LOG_FILE" ;;
        WARN)  echo -e "${YELLOW}[⚠]${NC} ${message}" | tee -a "$LOG_FILE" ;;
        ERROR) echo -e "${RED}[✗]${NC} ${message}" | tee -a "$LOG_FILE" ;;
        DEBUG) [[ "$VERBOSE" == "true" ]] && echo -e "${CYAN}[DEBUG]${NC} ${message}" | tee -a "$LOG_FILE" ;;
    esac
    
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
}

print_header() {
    echo ""
    echo -e "${BOLD}${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║     Cisco SD-WAN ESXi Deployment Automation v${SCRIPT_VERSION}     ║${NC}"
    echo -e "${BOLD}${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_section() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

spinner() {
    local pid=$1
    local message=$2
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    
    while kill -0 "$pid" 2>/dev/null; do
        local temp=${spinstr#?}
        printf " [%c] %s" "$spinstr" "$message"
        spinstr=$temp${spinstr%"$temp"}
        sleep 0.1
        printf "\r"
    done
    printf "    \r"
}

progress_bar() {
    local current=$1
    local total=$2
    local width=50
    local percentage=$((current * 100 / total))
    local filled=$((width * current / total))
    local empty=$((width - filled))
    
    printf "\r["
    printf "%${filled}s" | tr ' ' '█'
    printf "%${empty}s" | tr ' ' '░'
    printf "] %3d%% (%d/%d)" "$percentage" "$current" "$total"
}

# ============================================
# PREREQUISITE CHECKS
# ============================================

check_prerequisites() {
    print_section "Prerequisites Check"
    
    local errors=0
    
    # Check Ansible installation
    if ! command -v ansible &>/dev/null; then
        log ERROR "Ansible is not installed"
        ((errors++))
    else
        local ansible_version=$(ansible --version | head -1 | awk '{print $2}')
        log SUCCESS "Ansible $ansible_version detected"
    fi
    
    # Check Python
    if ! command -v python3 &>/dev/null; then
        log ERROR "Python 3 is not installed"
        ((errors++))
    else
        local python_version=$(python3 --version | awk '{print $2}')
        log SUCCESS "Python $python_version detected"
    fi
    
    # Check required collections
    local collections=("community.vmware" "cisco.ios" "ansible.netcommon")
    for collection in "${collections[@]}"; do
        if ansible-galaxy collection list | grep -q "$collection"; then
            log SUCCESS "Collection $collection installed"
        else
            log WARN "Collection $collection not found - installing..."
            ansible-galaxy collection install "$collection" &>>"$LOG_FILE" || ((errors++))
        fi
    done
    
    # Check required files
    local required_files=(
        "${PROJECT_ROOT}/deploy_sdwan.yml"
        "${PROJECT_ROOT}/validate_sdwan.yml"
        "${PROJECT_ROOT}/inventory/hosts.yml"
        "${PROJECT_ROOT}/vars/deployment_config.yml"
    )
    
    for file in "${required_files[@]}"; do
        if [[ -f "$file" ]]; then
            log SUCCESS "Found: $(basename "$file")"
        else
            log ERROR "Missing: $file"
            ((errors++))
        fi
    done
    
    # Check vCenter connectivity
    if [[ -f "${PROJECT_ROOT}/vars/deployment_config.yml" ]]; then
        local vcenter_host=$(grep "vcenter_host:" "${PROJECT_ROOT}/vars/deployment_config.yml" | awk '{print $2}' | tr -d '"')
        if [[ -n "$vcenter_host" ]] && ping -c 1 -W 5 "$vcenter_host" &>/dev/null; then
            log SUCCESS "vCenter reachable: $vcenter_host"
        else
            log WARN "Cannot reach vCenter: $vcenter_host"
        fi
    fi
    
    if [[ $errors -gt 0 ]]; then
        log ERROR "Prerequisites check failed with $errors error(s)"
        return 1
    fi
    
    log SUCCESS "All prerequisites satisfied"
    return 0
}

# ============================================
# DIRECTORY SETUP
# ============================================

setup_directories() {
    log INFO "Setting up working directories..."
    
    local dirs=("$LOG_DIR" "$REPORT_DIR" "$BACKUP_DIR" "$STATE_DIR")
    
    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            log DEBUG "Created directory: $dir"
        fi
    done
    
    log SUCCESS "Directory structure ready"
}

# ============================================
# STATE MANAGEMENT
# ============================================

save_state() {
    local state="$1"
    local data="$2"
    
    cat > "$STATE_FILE" <<EOF
{
  "timestamp": "$(date -Iseconds)",
  "state": "$state",
  "deployment_id": "$TIMESTAMP",
  "data": $data
}
EOF
    
    log DEBUG "State saved: $state"
}

load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    else
        echo "{}"
    fi
}

check_existing_deployment() {
    if [[ -f "$STATE_FILE" ]]; then
        local prev_state=$(jq -r '.state' "$STATE_FILE" 2>/dev/null || echo "unknown")
        
        if [[ "$prev_state" == "deployed" ]] && [[ "$FORCE_DEPLOY" != "true" ]]; then
            log WARN "Existing deployment detected (state: $prev_state)"
            echo -n "Continue anyway? [y/N]: "
            read -r response
            if [[ ! "$response" =~ ^[Yy]$ ]]; then
                log INFO "Deployment cancelled by user"
                exit 0
            fi
        fi
    fi
}

# ============================================
# DEPLOYMENT FUNCTIONS
# ============================================

deploy_controllers() {
    print_section "Deploying SD-WAN Controllers"
    
    local playbook="${PROJECT_ROOT}/deploy_sdwan.yml"
    local extra_args=""
    
    [[ "$VERBOSE" == "true" ]] && extra_args="-vvv"
    [[ "$DRY_RUN" == "true" ]] && extra_args="$extra_args --check"
    
    log INFO "Starting deployment process..."
    
    if ansible-playbook "$playbook" \
        -i "${PROJECT_ROOT}/inventory/hosts.yml" \
        $extra_args >> "$LOG_FILE" 2>&1; then
        
        log SUCCESS "Controllers deployed successfully"
        save_state "deployed" '{"status": "success"}'
        return 0
    else
        log ERROR "Deployment failed - check log: $LOG_FILE"
        save_state "failed" '{"status": "error", "phase": "deployment"}'
        return 1
    fi
}

validate_deployment() {
    print_section "Validating SD-WAN Control Plane"
    
    if [[ "$SKIP_VALIDATION" == "true" ]]; then
        log INFO "Validation skipped by user"
        return 0
    fi
    
    local playbook="${PROJECT_ROOT}/validate_sdwan.yml"
    local extra_args=""
    
    [[ "$VERBOSE" == "true" ]] && extra_args="-vvv"
    
    log INFO "Running comprehensive validation..."
    log INFO "This may take 10-15 minutes..."
    
    if ansible-playbook "$playbook" \
        -i "${PROJECT_ROOT}/inventory/hosts.yml" \
        --tags validation \
        $extra_args >> "$LOG_FILE" 2>&1; then
        
        log SUCCESS "Validation completed successfully"
        
        # Parse validation results
        local latest_report=$(ls -t "${REPORT_DIR}"/validation_*.json 2>/dev/null | head -1)
        if [[ -f "$latest_report" ]]; then
            local health_score=$(jq -r '.health_score' "$latest_report" 2>/dev/null || echo "N/A")
            local status=$(jq -r '.status' "$latest_report" 2>/dev/null || echo "UNKNOWN")
            
            log INFO "Health Score: $health_score/100"
            log INFO "Status: $status"
            
            if [[ "$status" == "SUCCESS" ]]; then
                save_state "validated" '{"status": "success", "health_score": '$health_score'}'
                return 0
            else
                log WARN "Validation passed but health score is below optimal"
                save_state "validated" '{"status": "warning", "health_score": '$health_score'}'
                return 0
            fi
        fi
        
        return 0
    else
        log ERROR "Validation failed - check log: $LOG_FILE"
        save_state "failed" '{"status": "error", "phase": "validation"}'
        return 1
    fi
}

post_deployment_config() {
    print_section "Post-Deployment Configuration"
    
    local playbook="${PROJECT_ROOT}/configure_sdwan.yml"
    
    if [[ ! -f "$playbook" ]]; then
        log INFO "No post-deployment configuration playbook found - skipping"
        return 0
    fi
    
    log INFO "Applying post-deployment configuration..."
    
    if ansible-playbook "$playbook" \
        -i "${PROJECT_ROOT}/inventory/hosts.yml" \
        >> "$LOG_FILE" 2>&1; then
        
        log SUCCESS "Configuration applied successfully"
        return 0
    else
        log WARN "Configuration had some issues - check log: $LOG_FILE"
        return 1
    fi
}

# ============================================
# REPORTING
# ============================================

generate_summary_report() {
    print_section "Deployment Summary"
    
    local state=$(load_state)
    local deployment_state=$(echo "$state" | jq -r '.state' 2>/dev/null || echo "unknown")
    local deployment_id=$(echo "$state" | jq -r '.deployment_id' 2>/dev/null || echo "$TIMESTAMP")
    
    echo ""
    echo -e "${BOLD}Deployment Summary${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Deployment ID:     $deployment_id"
    echo "Status:            $deployment_state"
    echo "Timestamp:         $(date)"
    echo "Log File:          $LOG_FILE"
    echo ""
    
    # Find latest validation report
    local latest_html=$(ls -t "${REPORT_DIR}"/validation_*.html 2>/dev/null | head -1)
    if [[ -f "$latest_html" ]]; then
        echo "Validation Report: $latest_html"
    fi
    
    echo ""
    echo -e "${BOLD}Next Steps:${NC}"
    echo "1. Access vManage UI: https://192.168.1.10"
    echo "2. Default credentials: admin/admin"
    echo "3. Review validation report for detailed status"
    echo "4. Configure device templates and policies"
    echo "5. Begin edge device onboarding"
    echo ""
    
    # Show quick health check if validation was successful
    if [[ "$deployment_state" == "validated" ]]; then
        local latest_json=$(ls -t "${REPORT_DIR}"/validation_*.json 2>/dev/null | head -1)
        if [[ -f "$latest_json" ]]; then
            echo -e "${BOLD}Quick Health Check:${NC}"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            
            local health=$(jq -r '.health_score' "$latest_json" 2>/dev/null || echo "N/A")
            local controllers=$(jq -r '.results.phase3.controllers_registered' "$latest_json" 2>/dev/null || echo "N/A")
            local connections=$(jq -r '.results.phase4.control_connections_up' "$latest_json" 2>/dev/null || echo "N/A")
            
            echo "Health Score:      $health/100"
            echo "Controllers:       $controllers"
            echo "Active Connections: $connections"
            echo ""
        fi
    fi
}

# ============================================
# CLEANUP FUNCTIONS
# ============================================

cleanup_deployment() {
    print_section "Cleanup Deployment"
    
    if [[ "$FORCE_DEPLOY" != "true" ]]; then
        echo ""
        log WARN "This will remove all deployed SD-WAN components!"
        echo -n "Type 'DELETE' to confirm: "
        read -r confirmation
        
        if [[ "$confirmation" != "DELETE" ]]; then
            log INFO "Cleanup cancelled"
            return 0
        fi
    fi
    
    log INFO "Starting cleanup process..."
    
    local playbook="${PROJECT_ROOT}/cleanup_sdwan.yml"
    
    if [[ -f "$playbook" ]]; then
        if ansible-playbook "$playbook" \
            -i "${PROJECT_ROOT}/inventory/hosts.yml" \
            >> "$LOG_FILE" 2>&1; then
            
            log SUCCESS "Cleanup completed successfully"
            
            # Clear state
            rm -f "$STATE_FILE"
            
            return 0
        else
            log ERROR "Cleanup failed - check log: $LOG_FILE"
            return 1
        fi
    else
        log ERROR "Cleanup playbook not found: $playbook"
        return 1
    fi
}

# ============================================
# HEALTH CHECK
# ============================================

run_health_check() {
    print_section "Health Check"
    
    local health_script="${SCRIPT_DIR}/health_check.sh"
    
    if [[ -f "$health_script" ]]; then
        log INFO "Running health monitoring..."
        
        if bash "$health_script"; then
            log SUCCESS "Health check completed"
            return 0
        else
            log WARN "Health check reported issues"
            return 1
        fi
    else
        log WARN "Health check script not found: $health_script"
        return 1
    fi
}

# ============================================
# SIGNAL HANDLING
# ============================================

cleanup_on_exit() {
    local exit_code=$?
    
    # Remove PID file
    rm -f "$PID_FILE"
    
    if [[ $exit_code -ne 0 ]]; then
        log ERROR "Deployment terminated with exit code: $exit_code"
        save_state "failed" '{"status": "interrupted", "exit_code": '$exit_code'}'
    fi
    
    exit $exit_code
}

trap cleanup_on_exit EXIT INT TERM

# ============================================
# USAGE INFORMATION
# ============================================

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Cisco SD-WAN ESXi Deployment Automation

OPTIONS:
    -h, --help              Show this help message
    -d, --deploy-only       Deploy controllers only (skip validation)
    -v, --validate-only     Run validation only (skip deployment)
    -c, --cleanup           Remove all deployed components
    -H, --health-check      Run health check only
    --force                 Skip confirmation prompts
    --dry-run               Simulate deployment without making changes
    --verbose               Enable verbose output
    --skip-validation       Skip validation phase
    --parallel              Enable parallel deployment (default)
    --version               Show script version

EXAMPLES:
    $(basename "$0")                    # Full deployment with validation
    $(basename "$0") --deploy-only      # Deploy only, skip validation
    $(basename "$0") --validate-only    # Validate existing deployment
    $(basename "$0") --cleanup --force  # Force cleanup without confirmation
    $(basename "$0") --health-check     # Run health monitoring

ENVIRONMENT VARIABLES:
    DEPLOY_MODE             Deployment mode (full|minimal|custom)
    SKIP_VALIDATION         Skip validation (true|false)
    FORCE_DEPLOY            Force deployment (true|false)
    DRY_RUN                 Dry run mode (true|false)
    VERBOSE                 Verbose output (true|false)

EOF
    exit 0
}

# ============================================
# MAIN EXECUTION
# ============================================

main() {
    local operation="full"
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                ;;
            -d|--deploy-only)
                operation="deploy"
                SKIP_VALIDATION="true"
                shift
                ;;
            -v|--validate-only)
                operation="validate"
                shift
                ;;
            -c|--cleanup)
                operation="cleanup"
                shift
                ;;
            -H|--health-check)
                operation="health"
                shift
                ;;
            --force)
                FORCE_DEPLOY="true"
                shift
                ;;
            --dry-run)
                DRY_RUN="true"
                shift
                ;;
            --verbose)
                VERBOSE="true"
                shift
                ;;
            --skip-validation)
                SKIP_VALIDATION="true"
                shift
                ;;
            --version)
                echo "SD-WAN Deployment Automation v${SCRIPT_VERSION}"
                exit 0
                ;;
            *)
                log ERROR "Unknown option: $1"
                usage
                ;;
        esac
    done
    
    # Create PID file
    echo $ > "$PID_FILE"
    
    # Display header
    print_header
    
    # Setup environment
    setup_directories
    
    # Check for existing deployment
    check_existing_deployment
    
    # Execute operation
    case $operation in
        full)
            check_prerequisites || exit 1
            deploy_controllers || exit 1
            sleep 60  # Wait for services to stabilize
            validate_deployment || exit 1
            post_deployment_config
            generate_summary_report
            ;;
        deploy)
            check_prerequisites || exit 1
            deploy_controllers || exit 1
            generate_summary_report
            ;;
        validate)
            validate_deployment || exit 1
            generate_summary_report
            ;;
        cleanup)
            cleanup_deployment || exit 1
            ;;
        health)
            run_health_check
            ;;
    esac
    
    log SUCCESS "Operation completed successfully!"
}

# Execute main function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi