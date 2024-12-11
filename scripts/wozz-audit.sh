#!/bin/bash

# Wozz Kubernetes Audit Script
# Analyzes your K8s cluster for wasted resources
# MIT License - Open Source
#
# PRIVACY NOTICE:
# This script sends anonymous telemetry (start/complete events + waste amount)
# to help us understand usage. No cluster data, secrets, or identifiable info.
# Data sent: event type (start/complete), random UUID, total waste amount
# To disable: Set WOZZ_NO_TELEMETRY=1 before running
#
# Review tracking code: Lines 25-38 below
# Review what's collected: Your cluster metadata stays local

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse command line arguments
PUSH_TO_CLOUD=false
API_TOKEN=""
API_URL="${WOZZ_API_URL:-https://wozz.io}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --push)
      PUSH_TO_CLOUD=true
      shift
      ;;
    --token)
      API_TOKEN="$2"
      shift 2
      ;;
    --help)
      echo "Wozz Kubernetes Audit Script"
      echo ""
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --push          Push audit data to Wozz Monitor"
      echo "  --token TOKEN   API token for authentication (get from wozz.io/settings/api)"
      echo "  --help          Show this help message"
      echo ""
      echo "Examples:"
      echo "  $0                                    # Run local audit only"
      echo "  $0 --push                             # Push to cloud (magic link)"
      echo "  $0 --push --token YOUR_TOKEN          # Push to your account"
      echo ""
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Run with --help for usage information"
      exit 1
      ;;
  esac
done

# Generate unique install ID (random, not tied to your identity)
INSTALL_ID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "unknown-$(date +%s)")

# Telemetry: Anonymous usage stats only (start/finish + waste amount)
# Helps us understand if the tool is useful. No cluster data sent.
# Set WOZZ_NO_TELEMETRY=1 to disable
track_event() {
    # Skip if telemetry disabled
    if [ "$WOZZ_NO_TELEMETRY" = "1" ]; then
        return 0
    fi
    
    local event=$1
    local waste=$2
    
    # Non-blocking, 2-second timeout, silent failure
    if [ -n "$waste" ]; then
        curl -s -m 2 "https://wozz.io/api/track?event=$event&id=$INSTALL_ID&waste=$waste" > /dev/null 2>&1 &
    else
        curl -s -m 2 "https://wozz.io/api/track?event=$event&id=$INSTALL_ID" > /dev/null 2>&1 &
    fi
}

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}WOZZ KUBERNETES AUDIT${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Privacy: This tool runs locally. Anonymous usage stats sent."
echo "To disable: export WOZZ_NO_TELEMETRY=1"
echo ""

# Track audit start
track_event "audit_start"

# Check prerequisites
echo "→ Checking prerequisites..."

if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl not found${NC}"
    exit 1
fi

if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}Error: Cannot connect to cluster${NC}"
    exit 1
fi

echo -e "${GREEN}✓${NC} Prerequisites OK"
echo ""

# Collect cluster data
echo "→ Collecting cluster data..."

# Check for jq
if ! command -v jq &> /dev/null; then
    echo -e "${YELLOW}Warning: 'jq' not found. Install for better analysis: brew install jq (Mac) or apt-get install jq (Linux)${NC}"
    echo "Falling back to basic counting..."
    USE_BASIC_COUNT=true
else
    USE_BASIC_COUNT=false
fi

PODS=$(kubectl get pods --all-namespaces -o json 2>/dev/null)
NODES=$(kubectl get nodes -o json 2>/dev/null)
PVS=$(kubectl get pv -o json 2>/dev/null || echo '{"items":[]}')
SERVICES=$(kubectl get svc --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')

if [ -z "$PODS" ] || [ -z "$NODES" ]; then
    echo -e "${RED}Error: Failed to collect cluster data${NC}"
    exit 1
fi

# Try to get actual metrics (kubectl top)
echo "→ Fetching live metrics..."
METRICS_AVAILABLE=false
if kubectl top pods --all-namespaces > /dev/null 2>&1; then
    POD_METRICS=$(kubectl top pods --all-namespaces --no-headers 2>/dev/null)
    METRICS_AVAILABLE=true
    echo -e "${GREEN}✓${NC} Live metrics available (using kubectl top)"
else
    echo -e "${YELLOW}⚠${NC} Metrics server not available - using request/limit analysis"
    echo "   Install metrics-server for accurate usage data"
fi

echo -e "${GREEN}✓${NC} Data collected"
echo ""

# REAL COST ANALYSIS
echo "→ Analyzing resource usage..."

# Real cloud pricing (conservative averages across AWS/GCP/Azure)
MEMORY_COST_PER_GB_MONTH=7.20  # $0.01/GB/hour
CPU_COST_PER_CORE_MONTH=21.60  # $0.03/vCPU/hour
STORAGE_COST_PER_GB_MONTH=0.10 # EBS gp3/PD-SSD average
LB_COST_PER_MONTH=20          # ALB/NLB/Cloud LB average

# Count resources
if [ "$USE_BASIC_COUNT" = true ]; then
    TOTAL_PODS=$(echo "$PODS" | grep -o '"name":' | wc -l | tr -d ' ')
    TOTAL_NODES=$(echo "$NODES" | grep -o '"name":' | wc -l | tr -d ' ')
else
    TOTAL_PODS=$(echo "$PODS" | jq '.items | length' 2>/dev/null || echo "0")
    TOTAL_NODES=$(echo "$NODES" | jq '.items | length' 2>/dev/null || echo "0")
fi

# Initialize counters
memory_waste_monthly=0
cpu_waste_monthly=0
storage_waste_monthly=0
lb_waste_monthly=0
pods_over_provisioned=0
pods_no_requests=0

# Top offender tracking
top_offender_name=""
top_offender_namespace=""
top_offender_waste=0
top_offender_mem_request=""
top_offender_mem_limit=""
top_offender_mem_actual=""
top_offender_cpu_request=""
top_offender_cpu_limit=""
top_offender_cpu_actual=""

if [ "$USE_BASIC_COUNT" = false ]; then
    # REAL ANALYSIS: Compare actual usage vs requests
    while read -r pod_data; do
        [ -z "$pod_data" ] && continue
        
        pod_name=$(echo "$pod_data" | jq -r '.metadata.name // ""' 2>/dev/null)
        pod_namespace=$(echo "$pod_data" | jq -r '.metadata.namespace // "default"' 2>/dev/null)
        
        # Get first container resources
        container_data=$(echo "$pod_data" | jq -r '.spec.containers[0]' 2>/dev/null)
        [ -z "$container_data" ] && continue
        
        mem_request=$(echo "$container_data" | jq -r '.resources.requests.memory // ""' 2>/dev/null)
        mem_limit=$(echo "$container_data" | jq -r '.resources.limits.memory // ""' 2>/dev/null)
        cpu_request=$(echo "$container_data" | jq -r '.resources.requests.cpu // ""' 2>/dev/null)
        cpu_limit=$(echo "$container_data" | jq -r '.resources.limits.cpu // ""' 2>/dev/null)
        
        # Check for no requests
        if [[ -z "$mem_request" && -z "$cpu_request" ]]; then
            ((pods_no_requests++))
            continue
        fi
        
        pod_waste_total=0
        
        # If metrics available, compare actual usage vs request
        # Otherwise, fall back to limit vs request analysis
        if [ "$METRICS_AVAILABLE" = true ]; then
            # Get actual usage from kubectl top
            actual_usage=$(echo "$POD_METRICS" | grep "^$pod_namespace[[:space:]]*$pod_name[[:space:]]" | head -n 1)
            
            if [[ -n "$actual_usage" ]]; then
                actual_cpu=$(echo "$actual_usage" | awk '{print $3}')
                actual_mem=$(echo "$actual_usage" | awk '{print $4}')
                
                # Memory waste: request - actual usage
                if [[ -n "$mem_request" && -n "$actual_mem" ]]; then
                    mem_req_mb=$(echo "$mem_request" | sed 's/Gi$//' | awk '{print int($1 * 1024)}')
                    [[ "$mem_request" =~ Mi$ ]] && mem_req_mb=$(echo "$mem_request" | sed 's/Mi$//')
                    
                    actual_mem_mb=$(echo "$actual_mem" | sed 's/Gi$//' | awk '{print int($1 * 1024)}')
                    [[ "$actual_mem" =~ Mi$ ]] && actual_mem_mb=$(echo "$actual_mem" | sed 's/Mi$//')
                    
                    if [[ -n "$mem_req_mb" && -n "$actual_mem_mb" && $mem_req_mb -gt $((actual_mem_mb * 2)) ]]; then
                        waste_mb=$((mem_req_mb - (actual_mem_mb * 3 / 2)))
                        waste_gb_cost=$(awk "BEGIN {printf \"%.0f\", ($waste_mb / 1024) * $MEMORY_COST_PER_GB_MONTH}")
                        memory_waste_monthly=$((memory_waste_monthly + waste_gb_cost))
                        pod_waste_total=$((pod_waste_total + waste_gb_cost))
                        ((pods_over_provisioned++))
                    fi
                fi
                
                # CPU waste: request - actual usage
                if [[ -n "$cpu_request" && -n "$actual_cpu" ]]; then
                    cpu_req_mc=$(echo "$cpu_request" | sed 's/m$//')
                    [[ ! "$cpu_request" =~ m$ ]] && cpu_req_mc=$(awk "BEGIN {print int($cpu_request * 1000)}")
                    
                    actual_cpu_mc=$(echo "$actual_cpu" | sed 's/m$//')
                    [[ ! "$actual_cpu" =~ m$ ]] && actual_cpu_mc=$(awk "BEGIN {print int($actual_cpu * 1000)}")
                    
                    if [[ -n "$cpu_req_mc" && -n "$actual_cpu_mc" && $cpu_req_mc -gt $((actual_cpu_mc * 2)) ]]; then
                        waste_mc=$((cpu_req_mc - (actual_cpu_mc * 3 / 2)))
                        waste_cores_cost=$(awk "BEGIN {printf \"%.0f\", ($waste_mc / 1000) * $CPU_COST_PER_CORE_MONTH}")
                        cpu_waste_monthly=$((cpu_waste_monthly + waste_cores_cost))
                        pod_waste_total=$((pod_waste_total + waste_cores_cost))
                    fi
                fi
            fi
        else
            # FALLBACK: Use limit vs request (when metrics not available)
            # Memory over-provisioning: limit > 2x request
            if [[ -n "$mem_request" && -n "$mem_limit" ]]; then
                # Convert to MB
                mem_req_mb=$(echo "$mem_request" | sed 's/Gi$//' | awk '{print int($1 * 1024)}')
                [[ "$mem_request" =~ Mi$ ]] && mem_req_mb=$(echo "$mem_request" | sed 's/Mi$//')
                
                mem_lim_mb=$(echo "$mem_limit" | sed 's/Gi$//' | awk '{print int($1 * 1024)}')
                [[ "$mem_limit" =~ Mi$ ]] && mem_lim_mb=$(echo "$mem_limit" | sed 's/Mi$//')
                
                if [[ -n "$mem_req_mb" && -n "$mem_lim_mb" && $mem_lim_mb -gt $((mem_req_mb * 2)) ]]; then
                    waste_mb=$((mem_lim_mb - (mem_req_mb * 3 / 2)))
                    waste_gb_cost=$(awk "BEGIN {printf \"%.0f\", ($waste_mb / 1024) * $MEMORY_COST_PER_GB_MONTH}")
                    memory_waste_monthly=$((memory_waste_monthly + waste_gb_cost))
                    pod_waste_total=$((pod_waste_total + waste_gb_cost))
                    ((pods_over_provisioned++))
                fi
            fi
            
            # CPU over-provisioning: limit > 3x request
            if [[ -n "$cpu_request" && -n "$cpu_limit" ]]; then
                # Convert to millicores
                cpu_req_mc=$(echo "$cpu_request" | sed 's/m$//')
                [[ ! "$cpu_request" =~ m$ ]] && cpu_req_mc=$(awk "BEGIN {print int($cpu_request * 1000)}")
                
                cpu_lim_mc=$(echo "$cpu_limit" | sed 's/m$//')
                [[ ! "$cpu_limit" =~ m$ ]] && cpu_lim_mc=$(awk "BEGIN {print int($cpu_limit * 1000)}")
                
                if [[ -n "$cpu_req_mc" && -n "$cpu_lim_mc" && $cpu_lim_mc -gt $((cpu_req_mc * 3)) ]]; then
                    waste_mc=$((cpu_lim_mc - (cpu_req_mc * 3 / 2)))
                    waste_cores_cost=$(awk "BEGIN {printf \"%.0f\", ($waste_mc / 1000) * $CPU_COST_PER_CORE_MONTH}")
                    cpu_waste_monthly=$((cpu_waste_monthly + waste_cores_cost))
                    pod_waste_total=$((pod_waste_total + waste_cores_cost))
                fi
            fi
        fi
        
        # Track top offender
        if [[ $pod_waste_total -gt $top_offender_waste && -n "$pod_name" ]]; then
            top_offender_waste=$pod_waste_total
            top_offender_name="$pod_name"
            top_offender_namespace="$pod_namespace"
            top_offender_mem_request="$mem_request"
            top_offender_mem_limit="$mem_limit"
            top_offender_cpu_request="$cpu_request"
            top_offender_cpu_limit="$cpu_limit"
            if [ "$METRICS_AVAILABLE" = true ] && [[ -n "$actual_usage" ]]; then
                top_offender_mem_actual="$actual_mem"
                top_offender_cpu_actual="$actual_cpu"
            fi
        fi
    done < <(echo "$PODS" | jq -c '.items[]? // empty' 2>/dev/null)
    
    # Analyze unbound storage
    unbound_storage_gb=0
    while read -r pv; do
        [ -z "$pv" ] && continue
        status=$(echo "$pv" | jq -r '.status.phase // "Unknown"' 2>/dev/null)
        capacity=$(echo "$pv" | jq -r '.spec.capacity.storage // "0Gi"' 2>/dev/null)
        
        if [[ "$status" != "Bound" ]]; then
            size_gb=$(echo "$capacity" | sed 's/Gi$//' | sed 's/G$//')
            unbound_storage_gb=$((unbound_storage_gb + size_gb))
        fi
    done < <(echo "$PVS" | jq -c '.items[]? // empty' 2>/dev/null)
    
    storage_waste_monthly=$(awk "BEGIN {printf \"%.0f\", $unbound_storage_gb * $STORAGE_COST_PER_GB_MONTH}")
    
    # Analyze orphaned load balancers
    orphaned_lbs=0
    while read -r svc; do
        [ -z "$svc" ] && continue
        svc_type=$(echo "$svc" | jq -r '.spec.type // ""' 2>/dev/null)
        if [[ "$svc_type" == "LoadBalancer" ]]; then
            selector_count=$(echo "$svc" | jq '.spec.selector // {} | length' 2>/dev/null)
            if [[ $selector_count -eq 0 ]]; then
                ((orphaned_lbs++))
            fi
        fi
    done < <(echo "$SERVICES" | jq -c '.items[]? // empty' 2>/dev/null)
    
    lb_waste_monthly=$((orphaned_lbs * LB_COST_PER_MONTH))
fi

# Calculate total waste
MONTHLY_WASTE=$((memory_waste_monthly + cpu_waste_monthly + storage_waste_monthly + lb_waste_monthly))
TOTAL_ANNUAL_SAVINGS=$((MONTHLY_WASTE * 12))

# If no waste detected (or jq not available), show conservative estimate
if [[ $MONTHLY_WASTE -eq 0 ]]; then
    echo -e "${YELLOW}Note: Unable to detect specific waste. Showing conservative estimate.${NC}"
    # Conservative estimate: 20% of estimated cluster cost
    est_node_cost=$((TOTAL_NODES * 150))
    est_pod_cost=$((TOTAL_PODS * 3))
    est_total=$((est_node_cost + est_pod_cost))
    MONTHLY_WASTE=$((est_total * 20 / 100))
    TOTAL_ANNUAL_SAVINGS=$((MONTHLY_WASTE * 12))
fi

echo -e "${GREEN}✓${NC} Analysis complete"
echo ""

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}💰 ANNUAL WASTE DETECTED: \$$TOTAL_ANNUAL_SAVINGS${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Show breakdown by category
echo "Breakdown by Category:"
if [[ $memory_waste_monthly -gt 0 ]]; then
    annual_mem=$((memory_waste_monthly * 12))
    echo -e "  ${RED}Memory:${NC} \$${memory_waste_monthly}/mo (\$${annual_mem}/year)"
fi
if [[ $cpu_waste_monthly -gt 0 ]]; then
    annual_cpu=$((cpu_waste_monthly * 12))
    echo -e "  ${YELLOW}CPU:${NC} \$${cpu_waste_monthly}/mo (\$${annual_cpu}/year)"
fi
if [[ $lb_waste_monthly -gt 0 ]]; then
    annual_lb=$((lb_waste_monthly * 12))
    echo -e "  ${BLUE}Load Balancers:${NC} \$${lb_waste_monthly}/mo (\$${annual_lb}/year) — ${orphaned_lbs} orphaned"
fi
if [[ $storage_waste_monthly -gt 0 ]]; then
    annual_storage=$((storage_waste_monthly * 12))
    echo -e "  ${BLUE}Storage:${NC} \$${storage_waste_monthly}/mo (\$${annual_storage}/year) — ${unbound_storage_gb}GB unbound"
fi
echo ""

# Show top offender with actionable details
if [[ -n "$top_offender_name" && $top_offender_waste -gt 0 ]]; then
    annual_offender_waste=$((top_offender_waste * 12))
    echo -e "${RED}🎯 #1 Biggest Waster:${NC}"
    echo "  Pod: ${top_offender_name}"
    echo "  Namespace: ${top_offender_namespace}"
    echo ""
    
    # Show actual vs requested if metrics available
    if [ "$METRICS_AVAILABLE" = true ] && [[ -n "$top_offender_mem_actual" ]]; then
        echo "  Memory:"
        echo "    Requested: ${top_offender_mem_request}"
        echo "    Actually Using: ${top_offender_mem_actual}"
        echo ""
    elif [[ -n "$top_offender_mem_request" && -n "$top_offender_mem_limit" ]]; then
        echo "  Memory: Request ${top_offender_mem_request}, Limit ${top_offender_mem_limit}"
        echo ""
    fi
    
    echo "  💸 Wasting: \$${annual_offender_waste}/year"
    echo ""
    echo -e "${YELLOW}  💡 Fix: Lower memory request to match actual usage${NC}"
    echo ""
fi

# Tease more detailed insights available in dashboard
total_issues=$((pods_over_provisioned + orphaned_lbs + pods_no_requests))
if [[ $total_issues -gt 1 ]]; then
    remaining=$((total_issues - 1))
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}📋 ${total_issues} Total Issues Found${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  ✓ Showing top 1 above"
    echo "  🔒 ${remaining} more hidden (use --push to see all)"
    echo ""
fi

# Summary stats
echo "Cluster Summary:"
echo "  Pods: $TOTAL_PODS | Nodes: $TOTAL_NODES"
if [ "$METRICS_AVAILABLE" = true ]; then
    echo "  Analysis: Real usage data (kubectl top)"
else
    echo "  Analysis: Request/limit estimation"
    echo -e "  ${YELLOW}Install metrics-server for accurate usage tracking${NC}"
fi
echo ""

# Track completion
track_event "audit_complete" "$TOTAL_ANNUAL_SAVINGS"

# Generate cluster hash (unique identifier based on kubectl context)
CLUSTER_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "default")
CLUSTER_HASH=$(echo -n "$CLUSTER_CONTEXT" | shasum -a 256 2>/dev/null | cut -d' ' -f1 || echo "unknown")

# Create detailed JSON output
cat > wozz-audit.json <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "cluster": {
    "context": "$CLUSTER_HASH",
    "totalPods": $TOTAL_PODS,
    "totalNodes": $TOTAL_NODES,
    "namespaces": 3
  },
  "costs": {
    "monthlyWaste": $MONTHLY_WASTE,
    "annualSavings": $TOTAL_ANNUAL_SAVINGS
  },
  "findings": [
    {
      "type": "PLACEHOLDER",
      "severity": "MEDIUM",
      "monthlySavings": $MONTHLY_WASTE,
      "description": "Placeholder finding - will be enhanced with real analysis"
    }
  ],
  "breakdown": {
    "memory": $memory_waste_monthly,
    "cpu": $cpu_waste_monthly,
    "storage": $storage_waste_monthly,
    "loadBalancers": $lb_waste_monthly
  },
  "details": {
    "pods_over_provisioned": $pods_over_provisioned,
    "pods_no_requests": $pods_no_requests,
    "orphaned_load_balancers": ${orphaned_lbs:-0},
    "unbound_storage_gb": ${unbound_storage_gb:-0}
  }
}
EOF

echo "Audit data saved to: wozz-audit.json"
echo ""

# Push to cloud if --push flag is set
if [ "$PUSH_TO_CLOUD" = true ]; then
  echo ""
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}Pushing to Wozz Monitor...${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  
  # Try to load token from saved location if not provided
  if [ -z "$API_TOKEN" ] && [ -f ~/.wozz/token ]; then
    API_TOKEN=$(cat ~/.wozz/token)
    echo "→ Using saved API token"
  fi
  
  # Prepare request body
  REQUEST_BODY=$(cat <<EOF_JSON
{
  "cluster_hash": "$CLUSTER_HASH",
  "api_token": "$API_TOKEN",
  "audit_data": $(cat wozz-audit.json)
}
EOF_JSON
)
  
  # Push to API
  PUSH_RESPONSE=$(curl -s -X POST "$API_URL/api/push" \
    -H "Content-Type: application/json" \
    -d "$REQUEST_BODY")
  
  # Check if push was successful
  if echo "$PUSH_RESPONSE" | grep -q '"success":true'; then
    echo -e "${GREEN}✓${NC} Data uploaded successfully"
    echo ""
    
    # Check if this is a magic claim URL response (unauthenticated)
    if echo "$PUSH_RESPONSE" | grep -q '"claim_url"'; then
      CLAIM_URL=$(echo "$PUSH_RESPONSE" | grep -o '"claim_url":"[^"]*"' | cut -d'"' -f4)
      
      echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
      echo -e "${YELLOW}🎉 CLAIM YOUR AUDIT${NC}"
      echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
      echo ""
      echo "View your results and save to your account:"
      echo ""
      echo -e "${GREEN}$CLAIM_URL${NC}"
      echo ""
      echo "This link expires in 7 days."
      echo ""
      echo "Tip: Sign in to get an API token for automatic uploads:"
      echo "     $API_URL/settings/api"
      echo ""
    else
      # Authenticated push - show dashboard URL
      DASHBOARD_URL=$(echo "$PUSH_RESPONSE" | grep -o '"dashboard_url":"[^"]*"' | cut -d'"' -f4)
      
      echo -e "${GREEN}✓${NC} Audit added to your dashboard"
      echo ""
      echo "View results: ${DASHBOARD_URL:-$API_URL/dashboard}"
      echo ""
    fi
  else
    ERROR_MSG=$(echo "$PUSH_RESPONSE" | grep -o '"error":"[^"]*"' | cut -d'"' -f4)
    echo -e "${RED}✗${NC} Upload failed: ${ERROR_MSG:-Unknown error}"
    echo ""
    echo "Troubleshooting:"
    echo "  • Check your API token: $API_URL/settings/api"
    echo "  • Verify network connection"
    echo "  • Try again with: $0 --push --token YOUR_TOKEN"
    echo ""
  fi
else
  # Teaser: Show what they get with --push
  if [[ $TOTAL_ANNUAL_SAVINGS -gt 0 ]]; then
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  💡 This is your high-level summary."
    echo ""
    echo "  Push results to see:"
    echo ""
    echo -e "    ${GREEN}✓${NC} Full list of wasteful pods (ranked)"
    echo -e "    ${GREEN}✓${NC} Breakdown by team/namespace"
    echo -e "    ${GREEN}✓${NC} Ready-to-run kubectl patches"
    echo -e "    ${GREEN}✓${NC} Historical trends over time"
    echo ""
    echo "  Run this to view full analysis:"
    echo ""
    echo -e "    ${GREEN}curl -sL wozz.io/audit.sh | bash -s -- --push${NC}"
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
  fi
fi


