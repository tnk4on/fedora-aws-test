#!/bin/bash
set -e

# Configuration - can be set via environment variables
VM_NAME="${VM_NAME:?Error: VM_NAME environment variable is required}"
VM_IP="${VM_IP:?Error: VM_IP environment variable is required}"
SSH_KEY_PATH="${SSH_KEY_PATH:?Error: SSH_KEY_PATH environment variable is required}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=10"
TEST_REPO_DIR="${TEST_REPO_DIR:-podman-devcontainer-test}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Running Tests on Fedora VM ===${NC}"
echo "VM Name: $VM_NAME"
echo "VM IP: $VM_IP"
echo "SSH Key: $SSH_KEY_PATH"
echo ""

# Verify SSH connection
if ! ssh $SSH_OPTS -o ConnectTimeout=5 -i "$SSH_KEY_PATH" core@"$VM_IP" "echo OK" 2>/dev/null; then
    echo -e "${RED}Error: Cannot connect to VM${NC}"
    echo "Please verify VM is running and SSH key is correct"
    exit 1
fi

# Run tests
echo -e "${GREEN}Running tests...${NC}"

run_test() {
    local test_name=$1
    local test_path=$2
    local check_command=$3
    
    echo -e "\n${YELLOW}=== Test: $test_name ===${NC}"
    ssh $SSH_OPTS -i "$SSH_KEY_PATH" core@"$VM_IP" <<ENDSSH
set -e
export NVM_DIR="\$HOME/.nvm" && . "\$NVM_DIR/nvm.sh"
cd ~/$TEST_REPO_DIR/$test_path
OUTPUT=\$(devcontainer up --workspace-folder . --docker-path podman 2>&1)
CONTAINER_ID=\$(echo "\$OUTPUT" | grep -o '"containerId":"[^"]*"' | cut -d'"' -f4 | head -1)
$check_command
podman rm -f "\$CONTAINER_ID" || true
echo "✅ $test_name PASSED"
ENDSSH
}

# Run all tests
run_test "Minimal" "tests/minimal" "echo 'Container created successfully'"
run_test "Dockerfile" "tests/dockerfile" "podman exec \"\$CONTAINER_ID\" curl --version"
run_test "Features (Go)" "tests/features-go" "podman exec \"\$CONTAINER_ID\" go version"
run_test "Docker in Docker" "tests/docker-in-docker" "
    echo 'Waiting for Docker daemon...'
    for i in {1..6}; do
      if podman exec \"\$CONTAINER_ID\" docker info >/dev/null 2>&1; then
        echo 'Docker daemon ready'
        break
      fi
      sleep 5
    done
    podman exec \"\$CONTAINER_ID\" docker run --rm hello-world
"
run_test "Sample Python" "tests/sample-python" "podman exec \"\$CONTAINER_ID\" python3 --version"
run_test "Sample Node.js" "tests/sample-node" "podman exec \"\$CONTAINER_ID\" node --version"
run_test "Sample Go" "tests/sample-go" "podman exec \"\$CONTAINER_ID\" go version"

echo -e "\n${GREEN}=== All tests completed! ===${NC}"

