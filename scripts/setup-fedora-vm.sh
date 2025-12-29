#!/bin/bash
set -e

# Configuration
AWS_REGION="${AWS_REGION:-us-west-2}"
VM_INSTANCE_TYPE="${VM_INSTANCE_TYPE:-t3.micro}"
VM_DISK_SIZE="${VM_DISK_SIZE:-200}"  # GB
VM_NAME="${VM_NAME:-fedora-test-$(date +%s)}"
KEY_NAME="${KEY_NAME:-fedora-key-${VM_NAME}}"
SECURITY_GROUP_NAME="${SECURITY_GROUP_NAME:-fedora-sg-${VM_NAME}}"
# SSH鍵: 環境変数で指定されていない場合は自動生成
SSH_KEY_PATH="${SSH_KEY_PATH:-${HOME}/.ssh/ec2_key_${VM_NAME}}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=10"
TEST_REPO="${TEST_REPO:-https://github.com/tnk4on/podman-devcontainer-test.git}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Cleanup function
cleanup_vm() {
    if [ -n "$INSTANCE_ID" ]; then
        echo -e "\n${YELLOW}Cleaning up EC2 instance: $INSTANCE_ID${NC}"
        aws ec2 terminate-instances \
            --instance-ids "$INSTANCE_ID" \
            --region "$AWS_REGION" >/dev/null 2>&1 || true
        
        # Wait for termination
        aws ec2 wait instance-terminated \
            --instance-ids "$INSTANCE_ID" \
            --region "$AWS_REGION" 2>/dev/null || true
    fi
    
    if [ -n "$SECURITY_GROUP_ID" ]; then
        echo -e "${YELLOW}Cleaning up security group: $SECURITY_GROUP_ID${NC}"
        aws ec2 delete-security-group \
            --group-id "$SECURITY_GROUP_ID" \
            --region "$AWS_REGION" >/dev/null 2>&1 || true
    fi
    
    if [ -n "$KEY_NAME" ]; then
        echo -e "${YELLOW}Cleaning up key pair: $KEY_NAME${NC}"
        aws ec2 delete-key-pair \
            --key-name "$KEY_NAME" \
            --region "$AWS_REGION" >/dev/null 2>&1 || true
    fi
    
    if [ "${SSH_KEY_AUTO_GENERATED:-false}" = "true" ] && [ -f "$SSH_KEY_PATH" ]; then
        rm -f "$SSH_KEY_PATH" "$SSH_KEY_PATH.pub"
    fi
}

# Set trap for cleanup (only if not sourced)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    trap cleanup_vm EXIT INT TERM
fi

echo -e "${GREEN}=== Fedora AWS EC2 VM Setup ===${NC}"
echo "Region: $AWS_REGION"
echo "VM Name: $VM_NAME"
echo "Instance Type: $VM_INSTANCE_TYPE"
echo ""

# Check prerequisites
if ! command -v aws &> /dev/null; then
    echo -e "${RED}Error: AWS CLI is not installed${NC}"
    echo "Install: https://aws.amazon.com/cli/"
    exit 1
fi

# Authenticate check
if ! aws sts get-caller-identity &>/dev/null; then
    echo -e "${RED}Error: AWS credentials not configured${NC}"
    echo "Run: aws configure"
    exit 1
fi

# Generate SSH key (if not provided)
if [ ! -f "$SSH_KEY_PATH" ]; then
    echo -e "${GREEN}Generating SSH key...${NC}"
    ssh-keygen -t rsa -b 4096 -f "$SSH_KEY_PATH" -N '' -q
    chmod 600 "$SSH_KEY_PATH"
    SSH_KEY_AUTO_GENERATED=true
else
    echo -e "${GREEN}Using existing SSH key: $SSH_KEY_PATH${NC}"
    SSH_KEY_AUTO_GENERATED=false
    chmod 600 "$SSH_KEY_PATH"
fi

# Check if public key exists
if [ ! -f "${SSH_KEY_PATH}.pub" ]; then
    echo -e "${RED}Error: Public key not found: ${SSH_KEY_PATH}.pub${NC}"
    exit 1
fi

# Import SSH key to AWS
echo -e "${GREEN}Importing SSH key to AWS...${NC}"
aws ec2 import-key-pair \
    --key-name "$KEY_NAME" \
    --public-key-material "fileb://${SSH_KEY_PATH}.pub" \
    --region "$AWS_REGION" >/dev/null 2>&1 || {
    echo -e "${YELLOW}Key pair may already exist, continuing...${NC}"
}

# Create security group
echo -e "${GREEN}Creating security group...${NC}"
SECURITY_GROUP_ID=$(aws ec2 create-security-group \
    --group-name "$SECURITY_GROUP_NAME" \
    --description "Security group for Fedora test runner" \
    --region "$AWS_REGION" \
    --query 'GroupId' --output text 2>/dev/null || \
    aws ec2 describe-security-groups \
        --group-names "$SECURITY_GROUP_NAME" \
        --region "$AWS_REGION" \
        --query 'SecurityGroups[0].GroupId' --output text)

# Allow SSH from anywhere
aws ec2 authorize-security-group-ingress \
    --group-id "$SECURITY_GROUP_ID" \
    --protocol tcp \
    --port 22 \
    --cidr 0.0.0.0/0 \
    --region "$AWS_REGION" >/dev/null 2>&1 || {
    echo -e "${YELLOW}SSH rule may already exist, continuing...${NC}"
}

# Find Fedora CoreOS AMI
echo -e "${GREEN}Finding Fedora CoreOS AMI...${NC}"
AMI_ID=$(aws ec2 describe-images \
    --owners 125523088429 \
    --filters "Name=name,Values=Fedora-CoreOS-*-x86_64" "Name=virtualization-type,Values=hvm" "Name=architecture,Values=x86_64" \
    --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
    --output text \
    --region "$AWS_REGION")

if [ -z "$AMI_ID" ] || [ "$AMI_ID" = "None" ]; then
    echo -e "${RED}Error: Could not find Fedora CoreOS AMI${NC}"
    exit 1
fi

echo "Using AMI: $AMI_ID"

# Create Fedora EC2 instance
echo -e "${GREEN}Creating Fedora CoreOS EC2 instance...${NC}"
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$VM_INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SECURITY_GROUP_ID" \
    --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":${VM_DISK_SIZE},\"VolumeType\":\"gp3\"}}]" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${VM_NAME}}]" \
    --region "$AWS_REGION" \
    --query 'Instances[0].InstanceId' --output text)

echo "Instance ID: $INSTANCE_ID"

# Wait for instance to be running
echo -e "${GREEN}Waiting for instance to be running...${NC}"
aws ec2 wait instance-running \
    --instance-ids "$INSTANCE_ID" \
    --region "$AWS_REGION"

# Get public IP
echo -e "${GREEN}Getting VM IP address...${NC}"
VM_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

if [ -z "$VM_IP" ] || [ "$VM_IP" = "None" ]; then
    echo -e "${RED}Error: Could not get public IP address${NC}"
    cleanup_vm
    exit 1
fi

echo "VM IP: $VM_IP"

# Wait for SSH
echo -e "${GREEN}Waiting for SSH to be available...${NC}"
MAX_ATTEMPTS=30
ATTEMPT=0
while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    if ssh $SSH_OPTS -o ConnectTimeout=5 -i "$SSH_KEY_PATH" core@"$VM_IP" "echo OK" 2>/dev/null; then
        echo -e "${GREEN}SSH is ready!${NC}"
        break
    fi
    ATTEMPT=$((ATTEMPT + 1))
    echo "Attempt $ATTEMPT/$MAX_ATTEMPTS..."
    sleep 5
done

if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
    echo -e "${RED}Error: SSH connection timeout${NC}"
    echo -e "${YELLOW}Deleting instance due to SSH timeout...${NC}"
    cleanup_vm
    exit 1
fi

# Verify basic environment
echo -e "${GREEN}Verifying VM environment...${NC}"
ssh $SSH_OPTS -i "$SSH_KEY_PATH" core@"$VM_IP" <<'ENDSSH'
echo "=== Environment ==="
cat /etc/os-release | head -3
podman --version
echo ""
echo "=== Podman configuration ==="
mkdir -p ~/.config/containers
echo 'unqualified-search-registries = ["docker.io"]' > ~/.config/containers/registries.conf
cat ~/.config/containers/registries.conf
ENDSSH

# Export VM information
echo ""
echo -e "${GREEN}=== VM Ready ===${NC}"
echo "Instance ID: $INSTANCE_ID"
echo "VM Name: $VM_NAME"
echo "VM IP: $VM_IP"
echo "SSH Key: $SSH_KEY_PATH"
echo "Security Group: $SECURITY_GROUP_ID"
# Export for parent script if sourced
export INSTANCE_ID VM_NAME VM_IP SSH_KEY_PATH SECURITY_GROUP_ID KEY_NAME AWS_REGION SSH_KEY_AUTO_GENERATED
echo ""
echo -e "${YELLOW}To connect manually:${NC}"
echo "  ssh -i $SSH_KEY_PATH core@$VM_IP"
echo ""
echo -e "${YELLOW}Next steps (manual setup):${NC}"
echo "  1. Install nvm: curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash"
echo "  2. Load nvm: export NVM_DIR=\"\$HOME/.nvm\" && . \"\$NVM_DIR/nvm.sh\""
echo "  3. Install Node.js: nvm install --lts"
echo "  4. Install @devcontainers/cli: npm install -g @devcontainers/cli"
echo "  5. Clone test repo: git clone $TEST_REPO"
echo ""
echo -e "${YELLOW}To run automated tests:${NC}"
echo "  export INSTANCE_ID=$INSTANCE_ID"
echo "  export VM_NAME=$VM_NAME"
echo "  export VM_IP=$VM_IP"
echo "  export SSH_KEY_PATH=$SSH_KEY_PATH"
echo "  ./scripts/run-tests-on-vm.sh"
echo ""
echo -e "${YELLOW}To delete instance (when done):${NC}"
echo "  aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region $AWS_REGION"

