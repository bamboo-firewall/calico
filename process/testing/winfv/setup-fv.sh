#!/bin/bash

# This script sets up a k8s cluster with one Linux node and one Windows node and run windows FV test.
# Usage - CNI plugin fv
#         copy calico.exe, calico-ipam.exe and win-fv.exe to $PWD and run this script.
#
#       - OS Felix fv
#         copy calico-felix.exe and win-fv.exe to $PWD and run this script.
#
#       - EE Felix fv
#         copy calico-felix.exe, win-fv.exe to $PWD
#         copy license.yaml, ~/go/src/github.com/projectcalico/libcalico-go/config/crd to $PWD/infra/ee
#         run this script

# Replace following parameters with your own value
# Prefix for cluster name
NAME_PREFIX="${NAME_PREFIX:=${USER}-win-fv}"

# Get K8S_VERSION variable from metadata.mk, default to a value if it cannot be found
SCRIPT_CURRENT_DIR="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
METADATAMK=${SCRIPT_CURRENT_DIR}/../../../metadata.mk
if [ -f ${METADATAMK} ]; then
    K8S_VERSION=$(grep K8S_VERSION ${METADATAMK} | cut -d "=" -f 2)
else
    K8S_VERSION=v1.27.11
fi

# Kubernetes version
KUBE_VERSION="${KUBE_VERSION:=${K8S_VERSION#v}}"

# AWS keypair name for nodes
WINDOWS_KEYPAIR_NAME="${WINDOWS_KEYPAIR_NAME:=AWS-key-pair}"

# Private key file for above AWS keypair
WINDOWS_PEM_FILE="${WINDOWS_PEM_FILE:=$HOME/AWS-key-pair.pem}"

# Private putty key file for above AWS keypair. Generated by puttygen from WINDOWS_PEM_FILE.
WINDOWS_PPK_FILE="${WINDOWS_PPK_FILE:=$HOME/AWS-key-pair.ppk}"

# Client Public IP to allow RDP into windows nodes.
# Normally it is your laptop public ip.
RDP_SOURCE_CIDR="${RDP_SOURCE_CIDR:=0.0.0.0/0}"

# Timeout value for windows FV in seconds. Default 60 minutes.
FV_TIMEOUT="${FV_TIMEOUT:=3600}"

# Backend could be 'bgp' or 'vxlan'.
BACKEND="${BACKEND:=bgp}"

# Specify windows server version [Windows1809container, Windows20H2container]
WINDOWS_OS="${WINDOWS_OS:=Windows2022container}"

# Specify container runtime to use: docker or containerd.
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:=docker}"

# Specify containerd version to use.
CONTAINERD_VERSION="${CONTAINERD_VERSION:=1.6.22}"

#specify description of AMI,this would be a filter to search AMI.
#we can create a Json file for description and use it. TODO????
AMI_1809_DESCRIPTION="Microsoft Windows Server 2019 with Containers Locale English AMI provided by Amazon"
AMI_1903_DESCRIPTION="Tigera-Windows Server 1903 image"

REGION="us-west-2"
CF_WIN_JSON_FILE="cloudformation-windows-server.json"

###################################################
# Do not modify the following code
###################################################

# when set to 1, don't prompt for agreement to proceed
QUIET=${QUIET:=0}

# when set to 1, uninstall everything
CLEANUP=${CLEANUP:=0}

# when set to 1, setup fv
SETUP_FV=${SETUP_FV:=1}

CLUSTER_NAME="${NAME_PREFIX}-fv"

CF_VPC_STACK_NAME="win-${CLUSTER_NAME}-vpc"
CF_FV_STACK_NAME="win-${CLUSTER_NAME}"

# Get FV_TYPE
if [ -f "./calico.exe" ]; then
    echo "./calico.exe exists, type cni-plugin"
    FV_TYPE="cni-plugin"
    cp ./run-fv-cni-plugin.ps1 ./run-fv.ps1
fi

if [ -f "./calico-felix.exe" ]; then
    echo "./calico-felix.exe exists, type calico-felix"
    FV_TYPE="calico-felix"
    cp ./run-fv-full.ps1 ./run-fv.ps1
fi

if [ -f "./infra/ee/license.yaml" ]; then
    echo "./infra/ee/license.yaml exists, type updated to tigera-felix"
    FV_TYPE="tigera-felix"
    sed -i "s?projectcalico.org/v3?crd.projectcalico.org/v1?g" ./infra/ee/license.yaml
    if [ ! -d "./infra/ee/crd" ]; then
      echo "./infra/ee/crd" does not exist.
      exit 1
    fi
fi

function prompt_to_continue() {
  if [ "$QUIET" -eq 0 ]; then
    read -n 1 -p "Proceed? (y/n): " answer

    echo
    if [ "$answer" != "y" ] && [ "$answer" != "Y" ]; then
      echo Exiting.
      exit 1
    fi
  fi
  echo Proceeding ...
}

function check_settings() {
  echo Settings:
  echo '  CLUSTER_NAME='${CLUSTER_NAME}
  echo '  KUBE_VERSION='${KUBE_VERSION}
  echo '  FV_TYPE='${FV_TYPE}

  if [ "$CLEANUP" -eq 1 ]; then
    echo
    echo -n "About to uninstall. "
  else
    echo '  WINDOWS_PEM_FILE='${WINDOWS_PEM_FILE}
    echo '  WINDOWS_KEYPAIR_NAME='${WINDOWS_KEYPAIR_NAME}
    echo '  RDP_SOURCE_CIDR='${RDP_SOURCE_CIDR}

    echo
    echo -n "About to install with home directory $HOME "

    if [ ! -f "./docker_auth.json" ]; then
      echo "./docker_auth.json" does not exist.
      exit 1
    fi

    if [ ! -f "./win-fv.exe" ]; then
      echo "./win-fv.exe" does not exist.
      exit 1
    fi
  fi
  prompt_to_continue
}

function install_aws_vpc_resources() {
  echo
  echo "Creating aws VPC resources with name ${CLUSTER_NAME} ..."

  aws cloudformation create-stack \
  --output json \
  --stack-name ${CF_VPC_STACK_NAME} \
  --parameters ParameterKey=ResourceName,ParameterValue="${CLUSTER_NAME}" \
  --template-body file://cloudformation-simple-vpc.json \
  --capabilities CAPABILITY_IAM > cf-log-vpc 2>&1

  # Wait for the stack to finish provisioning
  local STATUS=null
  for i in `seq 1 21`; do
    sleep 10
    STATUS=$(aws cloudformation describe-stacks \
    --output json \
    --stack-name ${CF_VPC_STACK_NAME} \
    | jq -r '.Stacks[].StackStatus')
    echo Checking stack status, attempt ${i}, got ${STATUS}
    if [ ${STATUS} == 'CREATE_COMPLETE' ]; then
      echo "aws vpc resources created."
      return 0
    fi
    if [ ${STATUS} == 'ROLLBACK_COMPLETE' ] ; then
      break
    fi
  done

  echo "Error running cloudformation script"
  cat cf-log-vpc
  aws cloudformation describe-stack-events \
    --output json \
    --stack-name ${CF_VPC_STACK_NAME}

  exit 1
}

function get_aws_vpc_info() {
  echo
  echo "Reading aws vpc information..."
  sleep 10
  local CF_OUTPUT=$(aws cloudformation describe-stacks --output json --stack-name ${CF_VPC_STACK_NAME})

  HYBRID_VPC_ID=$(echo ${CF_OUTPUT} | jq -r '.Stacks[].Outputs[] | select(.OutputKey=="VpcId").OutputValue')
  HYBRID_SUBNET_ID=$(echo ${CF_OUTPUT} | jq -r '.Stacks[].Outputs[] | select(.OutputKey=="SubnetId").OutputValue')
  K8S_NODE_SGS=$(echo ${CF_OUTPUT} | jq -r '.Stacks[].Outputs[] | select(.OutputKey=="SgId").OutputValue')
}

function get_ppk() {
  CONFIG_CONTENT=$(cat ${WINDOWS_PPK_FILE})
  PPK_CONFIG="${CONFIG_CONTENT}"
}

function install_aws_fv_windows_resources() {
  get_ppk

  echo
  echo "Creating aws linux and windows instances..."
  echo -e "\n\
VPC: ${HYBRID_VPC_ID}\n\
SUBNET: ${HYBRID_SUBNET_ID}\n\
NODE_SGS: ${K8S_NODE_SGS}\n\
KUBE_VERSION: ${KUBE_VERSION}\n"

  aws cloudformation create-stack \
  --output json \
  --stack-name ${CF_FV_STACK_NAME} \
  --parameters ParameterKey=PPKConfig,ParameterValue="${PPK_CONFIG}" \
               ParameterKey=WindowsOS,ParameterValue="${WINDOWS_OS}" \
               ParameterKey=BackEnd,ParameterValue="calico-${BACKEND}" \
               ParameterKey=KubeVersion,ParameterValue="${KUBE_VERSION}" \
               ParameterKey=CurrentVPC,ParameterValue=${HYBRID_VPC_ID} \
               ParameterKey=CurrentSubnet,ParameterValue=${HYBRID_SUBNET_ID} \
               ParameterKey=CurrentNodesSg,ParameterValue=${K8S_NODE_SGS} \
               ParameterKey=KeyName,ParameterValue=${WINDOWS_KEYPAIR_NAME} \
               ParameterKey=SourceCidrForRDP,ParameterValue=${RDP_SOURCE_CIDR} \
  --template-body file://${CF_WIN_JSON_FILE} \
  --capabilities CAPABILITY_IAM > cf-log 2>&1

  # Wait for the stack to finish provisioning
  local STATUS=null
  for i in `seq 1 21`; do
    sleep 10
    STATUS=$(aws cloudformation describe-stacks \
    --output json \
    --stack-name ${CF_FV_STACK_NAME} \
    | jq -r '.Stacks[].StackStatus')
    echo Checking stack status, attempt ${i}, got ${STATUS}
    if [ ${STATUS} == 'CREATE_COMPLETE' ] ; then
      echo "aws windows instances created."
      return 0
    fi
  done

  echo "Error running cloudformation script"
  cat cf-log
  aws cloudformation describe-stack-events \
    --output json \
    --stack-name ${CF_FV_STACK_NAME}

  exit 1
}

function ensure_windows_pem_file() {
  # Check if key is in PEM format - AWS needs PEM formatted keys to get Windows
  # passwords. If it isn't, make a copy, convert it, and use that instead.
  if grep -q "BEGIN OPENSSH PRIVATE KEY" ${WINDOWS_PEM_FILE}; then
    echo "WINDOWS_PEM_FILE (${WINDOWS_PEM_FILE}) is not a PEM file, making a copy and using it instead."
    cp ${WINDOWS_PEM_FILE} ${WINDOWS_PEM_FILE}.copy
    ssh-keygen -p -N "" -m PEM -f ${WINDOWS_PEM_FILE}.copy
    WINDOWS_PEM_FILE="${WINDOWS_PEM_FILE}.copy"
  fi
}

function wait_for_instance_password() {
  for i in `seq 1 60`; do
    sleep 10
    echo Trying to get windows password, attempt ${i}
    # Turn off trace so that the password is not echoed.
    set +x
    password=$(aws ec2 get-password-data --instance-id ${WINDOWS_INSTANCE} --priv-launch ${WINDOWS_PEM_FILE} | jq .PasswordData)
    set -x

    if [ "${password}" != "" ] && [ "${password}" != "null" ]; then
      echo Got windows password
      return 0
    fi
  done
  return 1
}

function show_all_instances() {
  echo
  echo "Reading aws windows FV instances information..."
  echo
  sleep 10
  local CF_OUTPUT=$(aws cloudformation describe-stacks --output json --stack-name ${CF_FV_STACK_NAME})

  LINUX_INSTANCE=$(echo ${CF_OUTPUT} | jq -r '.Stacks[].Outputs[] | select(.OutputKey=="InstanceId0").OutputValue')
  LINUX_EIP=$(echo ${CF_OUTPUT} | jq -r '.Stacks[].Outputs[] | select(.OutputKey=="InstanceEIP0").OutputValue')
  LINUX_PIP=$(echo ${CF_OUTPUT} | jq -r '.Stacks[].Outputs[] | select(.OutputKey=="InstancePIP0").OutputValue')

  MASTER_CONNECT_COMMAND="ssh -i ${WINDOWS_PEM_FILE} -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ubuntu@${LINUX_EIP}"
  if [ "$SETUP_FV" -eq 1 ]; then
    setup_fv
    # Copy config to winfv folder and make ubuntu the owner.
    ${MASTER_CONNECT_COMMAND} sudo cp /root/.kube/config /home/ubuntu/winfv
    ${MASTER_CONNECT_COMMAND} sudo chown ubuntu:ubuntu /home/ubuntu/winfv/config
  fi

  WINDOWS_INSTANCE=$(echo ${CF_OUTPUT} | jq -r '.Stacks[].Outputs[] | select(.OutputKey=="InstanceId1").OutputValue')
  WINDOWS_EIP=$(echo ${CF_OUTPUT} | jq -r '.Stacks[].Outputs[] | select(.OutputKey=="InstanceEIP1").OutputValue')
  WINDOWS_PIP=$(echo ${CF_OUTPUT} | jq -r '.Stacks[].Outputs[] | select(.OutputKey=="InstancePIP1").OutputValue')

  ensure_windows_pem_file
  wait_for_instance_password

  # Turn off trace so that the password is not echoed.
  set +x
  PASSWORD=$(aws ec2 get-password-data --instance-id  ${WINDOWS_INSTANCE} --priv-launch-key $WINDOWS_PEM_FILE | awk '{print $2}')
  set -x

  echo "Linux node: ubuntu@${LINUX_EIP}"
  echo "Windows node: ${WINDOWS_EIP}"
  echo "For credentials and other info, attach into the running job and go to ~/calico/process/testing/winfv and `cat connect`"

  CONNECT_FILE="connect"
  echo
  echo
  echo
  echo "-------------Connect to Linux Master Instances--------" >> ${CONNECT_FILE}
  echo "${MASTER_CONNECT_COMMAND}" >> ${CONNECT_FILE}
  echo "PrivateIP: ${LINUX_PIP}" >> ${CONNECT_FILE}
  echo
  echo "-------------Connect to Windows Instances-------------" >> ${CONNECT_FILE}
  echo "InstanceID:${WINDOWS_INSTANCE}     RDP://${WINDOWS_EIP} user: Administrator" >> ${CONNECT_FILE}
  # Turn off trace so that the password is not echoed.
  set +x
  echo "password: ${PASSWORD}" >> ${CONNECT_FILE}
  echo "PrivateIP: ${WINDOWS_PIP}" >> ${CONNECT_FILE}
  set -x
}

function wait_for_docker_installed() {
  echo "Waiting for docker to have been installed on linux node"
  for i in `seq 1 30`; do
    sleep 2
    ${MASTER_CONNECT_COMMAND} docker images

    if [ $? -eq 0 ]; then
      echo "Docker installed. Ready to setup linux node for FV"
      return 0
    fi
  done
  return 1
}

function wait_for_containerd_installed() {
  echo "Waiting for containerd to have been installed on linux node"
  for i in `seq 1 30`; do
    sleep 2
    ${MASTER_CONNECT_COMMAND} crictl images

    if [ $? -eq 0 ]; then
      echo "containerd installed. Ready to setup linux node for FV"
      return 0
    fi
  done
  return 1
}

function master_scp() {
  local file=$1
  scp -i ${WINDOWS_PEM_FILE} -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no $file ubuntu@${LINUX_EIP}:/home/ubuntu
}

function setup_linux() {

  # Prepare docker login script. This allow linux node to pull gcr.io images.
  echo -n "Logging in to gcr.io ... "

  echo '#!/bin/bash' > gcr_login.sh
  echo 'docker login -u _json_key -p "$(cat docker_auth.json)" https://gcr.io' >> gcr_login.sh
  chmod +x gcr_login.sh

  # Prepare wait for result script. This allow linux node to wait until it gets FV result from windows.
  cat << EOF > wait-report.sh
#!/bin/bash
echo "Wait for FV report... Timeout: ${FV_TIMEOUT} seconds"
for i in \$(seq 1 $FV_TIMEOUT)
do
    if  [ -f /home/ubuntu/report/done-marker ]; then
      echo "FV result is done."
      exit 0
    fi
    if [ \$(( \$i % 20 )) -eq 0 ]; then
      echo "checking for FV result..."
    fi
    sleep 1
done
EOF

  chmod +x wait-report.sh

  # set parameters for run-fv.ps1
  sed -i "s?<your kube version>?${KUBE_VERSION}?g" run-fv.ps1
  sed -i "s?<your linux pip>?${LINUX_PIP}?g" run-fv.ps1
  sed -i "s?<your os version>?${WINDOWS_OS}?g" run-fv.ps1
  sed -i "s?<your container runtime>?${CONTAINER_RUNTIME}?g" run-fv.ps1
  sed -i "s?<your containerd version>?${CONTAINERD_VERSION}?g" run-fv.ps1
  sed -i "s?<your fv type>?${FV_TYPE}?g" run-fv.ps1

  ${MASTER_CONNECT_COMMAND} mkdir -p winfv
  # Copy every files under current directory to linux node.
  # This include docker-auth, windows binaries, shell scripts.
  scp -i ${WINDOWS_PEM_FILE} -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -r ./* ubuntu@${LINUX_EIP}:/home/ubuntu/winfv/

  ${MASTER_CONNECT_COMMAND} ./gcr_login.sh
  ${MASTER_CONNECT_COMMAND} mkdir /home/ubuntu/report

  echo "done."
}
function setup_kubeadm_cluster(){
	scp -i ${WINDOWS_PEM_FILE} -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ./create_kubeadm_cluster.sh ubuntu@${LINUX_EIP}:/home/ubuntu/
	${MASTER_CONNECT_COMMAND} sudo chmod +x /home/ubuntu/create_kubeadm_cluster.sh
	${MASTER_CONNECT_COMMAND} sudo bash /home/ubuntu/create_kubeadm_cluster.sh ${KUBE_VERSION} ${BACKEND} ${FV_TYPE}
}
function setup_fv() {
  wait_for_docker_installed
  wait_for_containerd_installed

  setup_linux
  setup_kubeadm_cluster
  #create etcd manually with http protocol
  LOCAL_IP_ENV=${LINUX_PIP}
  ETCD_CONTAINER=quay.io/coreos/etcd:v3.3.7
  ${MASTER_CONNECT_COMMAND} docker run --detach -p 2389:2389 --name calico-etcd ${ETCD_CONTAINER}  etcd --advertise-client-urls "http://${LOCAL_IP_ENV}:2389,http://127.0.0.1:2389,http://${LOCAL_IP_ENV}:8001,http://127.0.0.1:8001" --listen-client-urls "http://0.0.0.0:2389,http://0.0.0.0:8001"

  echo
  ${MASTER_CONNECT_COMMAND} docker ps -a
  echo
  echo "Setup linux is done."
  echo
  echo
}

function output_connection() {
  echo '  CLUSTER_NAME='${CLUSTER_NAME}
  echo '  KUBE_VERSION='${KUBE_VERSION}
  echo
  SETUP_FV=0
  show_all_instances
}

function parse_options() {
  usage() {
    cat <<HELP_USAGE
Usage: $(basename "$0")
          [-o]                # ouput cluster connect information
          [-u]                # Uninstall cluster
          [-q]                # Quiet (don't prompt)
          [-h]                # Print usage

HELP_USAGE
    exit 1
  }

  local OPTIND
  while getopts "hoqu" opt; do
    case ${opt} in
      o )
           output_connection
           exit
           ;;
      q )  QUIET=1;;
      u )  CLEANUP=1;;
      h )  usage;;
      \? ) usage;;
    esac
  done
  shift $((OPTIND -1))
}

function uninstall_cluster() {
  echo
  echo "Removing windows and linux instances, please wait..."

  aws cloudformation delete-stack --output json --stack-name ${CF_FV_STACK_NAME}

  # Wait for the stack to finish provisioning
  local STATUS=null
  for i in `seq 1 21`; do
    sleep 1
    STATUS=$(aws cloudformation describe-stacks \
    --output json \
    --stack-name ${CF_FV_STACK_NAME} \
    | jq -r '.Stacks[].StackStatus')
    if [ "${STATUS}" == 'DELETE_COMPLETE' ] ; then
      echo "aws windows instances deleted."
      return 0
    fi
  done

  echo
  echo "Removing vpc resource, please wait..."

  aws cloudformation delete-stack --output json --stack-name ${CF_VPC_STACK_NAME}

  # Wait for the stack to finish provisioning
  local STATUS=null
  for i in `seq 1 21`; do
    sleep 1
    STATUS=$(aws cloudformation describe-stacks \
    --output json \
    --stack-name ${CF_VPC_STACK_NAME} \
    | jq -r '.Stacks[].StackStatus')
    if [ "${STATUS}" == 'DELETE_COMPLETE' ] ; then
      echo "aws vpc resources deleted."
      return 0
    fi
  done

  rm -f cf-log*
  echo "FV cluster removed."
}

# function to lookup AMI, if not present then update with latest one.
function lookup_win_cf_ami() {
  # get ami id from cloudformation
  local WIN_AMI=`cat ${CF_WIN_JSON_FILE} | jq --arg region "${REGION}" --arg windows_os "${WINDOWS_OS}" -r '.Mappings.AWSRegion2AMI[$region][$windows_os]'`

  # windows AMI name filter strings
  local AMI_1809_NAME="Windows_Server-2019-English-Core-Base-*"
  local AMI_2022_NAME="Windows_Server-2022-English-Core-Base-*"

  AMI_NAME=""
  if [ $WINDOWS_OS == "Windows1809container" ];then
    AMI_NAME="${AMI_1809_NAME}"
  elif [ $WINDOWS_OS == "Windows2022container" ];then
    AMI_NAME="${AMI_2022_NAME}"
  fi

  # search latest AMI based on AMI name
  local AMI=`aws ec2 describe-images --owners self amazon --filters "Name=name,Values=${AMI_NAME}" --query 'sort_by(Images, &CreationDate)[].ImageId' --output json | jq '(reverse)[0]'`
  REPLACE_AMI="${AMI//\"}"

  # check if we get empty AMI (in case of 1903 for now), then continue with AMI in CF json file
  if [ "${REPLACE_AMI}" != "" ] && [ "${REPLACE_AMI}" != "null" ] && [ "${REPLACE_AMI}" != "${WIN_AMI}" ];then
    echo "ec2 $WINDOWS_OS AMI ID $WIN_AMI updated to ${REPLACE_AMI}"
    sed -i "s?\"${WIN_AMI}\"?\"${REPLACE_AMI}\"?g" ${CF_WIN_JSON_FILE}
  else
    echo "No AMI update, continue with $WIN_AMI"
  fi
}

#
# Main()
#
parse_options "$@"

check_settings

if [ "$CLEANUP" -eq 1 ]; then
  uninstall_cluster
  exit
fi
echo "[INFO] lookup for update on windows AMI"
lookup_win_cf_ami

echo "[INFO] going to create a FV cluster"

install_aws_vpc_resources

get_aws_vpc_info

install_aws_fv_windows_resources

show_all_instances

echo
echo "All done."
