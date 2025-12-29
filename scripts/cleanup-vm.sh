#!/bin/bash
set -e

# Cleanup script for manually deleting Fedora EC2 instance and associated resources
# Usage: ./scripts/cleanup-vm.sh
# Environment variables required:
#   INSTANCE_ID - EC2 instance ID
#   SECURITY_GROUP_ID - Security group ID (optional)
#   KEY_NAME - Key pair name (optional)
#   AWS_REGION - AWS region (default: us-west-2)

AWS_REGION="${AWS_REGION:-us-west-2}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Fedora AWS EC2 Cleanup ===${NC}"
echo "Region: $AWS_REGION"
echo ""

# Check prerequisites
if ! command -v aws &> /dev/null; then
    echo -e "${RED}Error: AWS CLI is not installed${NC}"
    exit 1
fi

if ! aws sts get-caller-identity &>/dev/null; then
    echo -e "${RED}Error: AWS credentials not configured${NC}"
    exit 1
fi

# If INSTANCE_ID is not set, try to find running instances
if [ -z "$INSTANCE_ID" ]; then
    echo -e "${YELLOW}INSTANCE_ID not set. Searching for running Fedora test instances...${NC}"
    echo ""
    
    # List running instances with fedora-test prefix
    INSTANCES=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --filters "Name=tag:Name,Values=fedora-test-*" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
        --query 'Reservations[*].Instances[*].[InstanceId,Tags[?Key==`Name`].Value|[0],State.Name,PublicIpAddress]' \
        --output text)
    
    if [ -z "$INSTANCES" ]; then
        echo -e "${GREEN}No running Fedora test instances found.${NC}"
        exit 0
    fi
    
    echo "Found the following instances:"
    echo "-------------------------------------------"
    echo "$INSTANCES" | while read -r id name state ip; do
        echo "  Instance ID: $id"
        echo "  Name: $name"
        echo "  State: $state"
        echo "  IP: ${ip:-N/A}"
        echo "-------------------------------------------"
    done
    
    echo ""
    echo -e "${YELLOW}To delete a specific instance, run:${NC}"
    echo "  export INSTANCE_ID=<instance-id>"
    echo "  ./scripts/cleanup-vm.sh"
    echo ""
    echo -e "${YELLOW}Or delete all instances with:${NC}"
    echo "  export DELETE_ALL=true"
    echo "  ./scripts/cleanup-vm.sh"
    
    if [ "${DELETE_ALL}" = "true" ]; then
        echo ""
        echo -e "${YELLOW}Deleting all Fedora test instances...${NC}"
        echo "$INSTANCES" | while read -r id name state ip; do
            if [ -n "$id" ]; then
                echo "Terminating instance: $id ($name)"
                aws ec2 terminate-instances \
                    --instance-ids "$id" \
                    --region "$AWS_REGION" >/dev/null 2>&1 || true
            fi
        done
        
        echo "Waiting for instances to terminate..."
        sleep 10
        
        # Cleanup security groups
        echo "Cleaning up security groups..."
        aws ec2 describe-security-groups \
            --region "$AWS_REGION" \
            --filters "Name=group-name,Values=fedora-sg-*" \
            --query 'SecurityGroups[*].GroupId' \
            --output text | tr '\t' '\n' | while read -r sg_id; do
            if [ -n "$sg_id" ]; then
                echo "Deleting security group: $sg_id"
                aws ec2 delete-security-group \
                    --group-id "$sg_id" \
                    --region "$AWS_REGION" >/dev/null 2>&1 || true
            fi
        done
        
        # Cleanup key pairs
        echo "Cleaning up key pairs..."
        aws ec2 describe-key-pairs \
            --region "$AWS_REGION" \
            --filters "Name=key-name,Values=fedora-key-*" \
            --query 'KeyPairs[*].KeyName' \
            --output text | tr '\t' '\n' | while read -r key_name; do
            if [ -n "$key_name" ]; then
                echo "Deleting key pair: $key_name"
                aws ec2 delete-key-pair \
                    --key-name "$key_name" \
                    --region "$AWS_REGION" >/dev/null 2>&1 || true
            fi
        done
        
        echo -e "${GREEN}Cleanup complete!${NC}"
    fi
    
    exit 0
fi

echo "Instance ID: $INSTANCE_ID"

# Terminate instance
echo -e "${YELLOW}Terminating EC2 instance: $INSTANCE_ID${NC}"
aws ec2 terminate-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$AWS_REGION" || {
    echo -e "${RED}Failed to terminate instance${NC}"
    exit 1
}

# Wait for termination
echo "Waiting for instance to terminate..."
aws ec2 wait instance-terminated \
    --instance-ids "$INSTANCE_ID" \
    --region "$AWS_REGION" 2>/dev/null || true

echo -e "${GREEN}Instance terminated.${NC}"

# Delete security group if specified
if [ -n "$SECURITY_GROUP_ID" ]; then
    echo -e "${YELLOW}Deleting security group: $SECURITY_GROUP_ID${NC}"
    aws ec2 delete-security-group \
        --group-id "$SECURITY_GROUP_ID" \
        --region "$AWS_REGION" >/dev/null 2>&1 || {
        echo -e "${YELLOW}Warning: Could not delete security group (may still be in use)${NC}"
    }
fi

# Delete key pair if specified
if [ -n "$KEY_NAME" ]; then
    echo -e "${YELLOW}Deleting key pair: $KEY_NAME${NC}"
    aws ec2 delete-key-pair \
        --key-name "$KEY_NAME" \
        --region "$AWS_REGION" >/dev/null 2>&1 || true
fi

echo ""
echo -e "${GREEN}=== Cleanup Complete ===${NC}"

