#!/bin/bash
set -e

# This script combines setup and test execution
# For separate execution, use:
#   ./scripts/setup-fedora-vm.sh
#   ./scripts/run-tests-on-vm.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
AWS_REGION="${AWS_REGION:-us-west-2}"
VM_INSTANCE_TYPE="${VM_INSTANCE_TYPE:-t3.micro}"
VM_DISK_SIZE="${VM_DISK_SIZE:-200}"  # GB
VM_NAME="${VM_NAME:-fedora-test-$(date +%s)}"
SSH_KEY_PATH="${SSH_KEY_PATH:-${HOME}/.ssh/ec2_key_${VM_NAME}}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=10"
TEST_REPO="${TEST_REPO:-https://github.com/tnk4on/podman-devcontainer-test.git}"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Cleanup function
cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    if [ -n "$INSTANCE_ID" ]; then
        aws ec2 terminate-instances \
            --instance-ids "$INSTANCE_ID" \
            --region "$AWS_REGION" >/dev/null 2>&1 || true
    fi
    if [ -n "$SECURITY_GROUP_ID" ]; then
        # Wait for instance termination before deleting security group
        if [ -n "$INSTANCE_ID" ]; then
            aws ec2 wait instance-terminated \
                --instance-ids "$INSTANCE_ID" \
                --region "$AWS_REGION" 2>/dev/null || true
        fi
        aws ec2 delete-security-group \
            --group-id "$SECURITY_GROUP_ID" \
            --region "$AWS_REGION" >/dev/null 2>&1 || true
    fi
    if [ -n "$KEY_NAME" ]; then
        aws ec2 delete-key-pair \
            --key-name "$KEY_NAME" \
            --region "$AWS_REGION" >/dev/null 2>&1 || true
    fi
    if [ "${SSH_KEY_AUTO_GENERATED:-false}" = "true" ] && [ -f "$SSH_KEY_PATH" ]; then
        rm -f "$SSH_KEY_PATH" "$SSH_KEY_PATH.pub"
    fi
}

# Set trap for cleanup
trap cleanup EXIT INT TERM

# Run setup - source the script to get variables directly
echo -e "${GREEN}=== Step 1: Setting up VM ===${NC}"

# Temporarily disable cleanup trap and exit on error to avoid conflicts
trap - EXIT INT TERM
set +e

# Source setup script to get VM variables
# Note: setup-fedora-vm.sh will export VM_NAME, VM_IP, SSH_KEY_PATH
# Also note: setup-fedora-vm.sh has its own cleanup function that will delete VM on error
source "$SCRIPT_DIR/setup-fedora-vm.sh"
SETUP_EXIT_CODE=$?

# Restore settings
set -e
trap cleanup EXIT INT TERM

if [ $SETUP_EXIT_CODE -ne 0 ]; then
    echo "Error: VM setup failed"
    # VM should already be deleted by setup script's cleanup, but ensure cleanup
    if [ -n "$VM_NAME" ]; then
        cleanup
    fi
    exit 1
fi

# Verify variables are set
if [ -z "$INSTANCE_ID" ] || [ -z "$VM_NAME" ] || [ -z "$VM_IP" ] || [ -z "$SSH_KEY_PATH" ]; then
    echo "Error: VM information not set correctly"
    echo "INSTANCE_ID: $INSTANCE_ID"
    echo "VM_NAME: $VM_NAME"
    echo "VM_IP: $VM_IP"
    echo "SSH_KEY_PATH: $SSH_KEY_PATH"
    exit 1
fi

# Export VM info for test script (already exported by setup script, but ensure)
export INSTANCE_ID
export VM_NAME
export VM_IP
export SSH_KEY_PATH
export SECURITY_GROUP_ID
export KEY_NAME
export AWS_REGION

# Setup environment on VM (Node.js, devcontainer CLI, clone repo)
echo ""
echo -e "${GREEN}=== Step 2: Setting up test environment on VM ===${NC}"
ssh $SSH_OPTS -i "$SSH_KEY_PATH" core@"$VM_IP" <<ENDSSH
set -e
echo "=== Installing Node.js via nvm ==="
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && . "\$NVM_DIR/nvm.sh"
nvm install --lts

echo "=== Installing @devcontainers/cli ==="
npm install -g @devcontainers/cli
devcontainer --version

echo "=== Cloning test repository ==="
git clone "$TEST_REPO" || (cd podman-devcontainer-test && git pull)
ENDSSH

# Run tests
echo ""
echo -e "${GREEN}=== Step 3: Running tests ===${NC}"
"$SCRIPT_DIR/run-tests-on-vm.sh"

echo ""
echo -e "${GREEN}=== Complete ===${NC}"

