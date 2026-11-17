#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# inspect.sh <bundle name> [--bucket <name>] [--prefix <prefix>] [--key <ec2 key pair>]
#            [--group <security group id>] [--profile <instance profile>] [--ami <id> | --no-ami]
#            [--ami-owner <account>] [--type <metal instance type>] [--spot] [--keep]
# A failure's timeline, looked at from a cloud machine of bare metal (the user's call, 2026-11-15:
# never nested virtualization for people, 5 to 12 times slower than metal): an m5zn.metal (24
# cores, 188 GiB, about $1 an hour on spot, $3.96 on demand) set up to open bundles (setup.sh
# --inspect: our KVM module; the bundle carries the guest, the system and the run's own
# explorer), which pulls the bundle from S3 (bundle-s3.sh pull: only the blobs it lacks) and opens
# it at its moment (INSPECT.sh: the moment's snapshot loaded in seconds, no replay from the
# start). From the base AMI: launch to the moment open in under two minutes (2026-11-15).
#
# The bundle is made on the recording host: infra/host/bundle-moment.sh <run> <timeline> <ms> <out>
# <store>, then bundle-s3.sh push <store> <out> s3://<bucket>/<prefix>. Runs recorded since
# 2026-11-10 show their guest a CPU without MPX, VMX and RSBA, which Granite Rapids can present;
# older ones replay on Skylake-SP and Cascade Lake only (docs/AWS.md).
#
# From the base AMI (inspect-ami.sh --type m5zn.metal: set up and sealed, so no setup here; the
# newest determinismo-base-* this account owns or may launch, shared by --ami-owner's account)
# when there is one, else Debian 13's AMI set up with setup.sh --inspect (about 23 minutes more,
# its OS reboot on metal 12 of them; needs this repository).
#
# Needs: the AWS CLI with credentials that may launch instances; an instance profile
# (`determinismo-inspect` unless --profile) whose role reads the bucket (docs/INSPECT.md shows its
# policy; another account's bucket shared with infra/aws/share.sh); a key pair and a security
# group letting your address in on SSH. The machine is left running for you (its address
# and `ssh admin@<ip>` printed) unless the bundle failed to open; terminate it when done (the
# command is printed). --keep never terminates it, even on a failure.
# The bucket, the security group and the AMIs' owner: options, or DETERMINISMO_BUCKET,
# DETERMINISMO_GROUP and DETERMINISMO_AMI_OWNER (your account by default).
#   infra/aws/inspect.sh <bundle> --bucket <bucket> --group <security group>
set -euo pipefail
bundle=${1:?usage: inspect.sh <bundle name> [--bucket <name>] [--prefix <prefix>] [--key <key pair>] [--group <sg>] [--profile <name>] [--ami <id> | --no-ami] [--ami-owner <account>] [--keep]}
shift
bucket=${DETERMINISMO_BUCKET:-}
prefix=determinismo
key=determinismo
group=${DETERMINISMO_GROUP:-}
profile=determinismo-inspect
ami=auto
ami_owner=${DETERMINISMO_AMI_OWNER:-self}
keep=false
type=m5zn.metal
spot=false
region=${AWS_REGION:-us-east-1}
while [ $# -gt 0 ]; do
  case $1 in
    --bucket) bucket=$2; shift 2 ;;
    --prefix) prefix=$2; shift 2 ;;
    --key) key=$2; shift 2 ;;
    --group) group=$2; shift 2 ;;
    --profile) profile=$2; shift 2 ;;
    --ami) ami=$2; shift 2 ;;
    --no-ami) ami=none; shift ;;
    --ami-owner) ami_owner=$2; shift 2 ;;
    --type) type=$2; shift 2 ;;
    --spot) spot=true; shift ;;
    --keep) keep=true; shift ;;
    *) echo "inspect.sh: unknown option $1" >&2; exit 2 ;;
  esac
done
[ -n "$bucket" ] || { echo "inspect.sh: the bundles' bucket: --bucket <name> or DETERMINISMO_BUCKET" >&2; exit 2; }
[ -n "$group" ] || { echo "inspect.sh: a security group with SSH from you: --group <id> or DETERMINISMO_GROUP" >&2; exit 2; }
owners=(self)
[ "$ami_owner" = self ] || owners+=("$ami_owner")
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)

if [ "$ami" = auto ]; then
  ami=$(aws ec2 describe-images --region "$region" --owners "${owners[@]}" \
    --filters 'Name=name,Values=determinismo-base-*' 'Name=state,Values=available' \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)
  [ "$ami" != None ] || ami=none
fi
if [ "$ami" = none ]; then
  image=$(aws ec2 describe-images --region "$region" --owners 136693071363 \
    --filters 'Name=name,Values=debian-13-amd64-*' 'Name=architecture,Values=x86_64' \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)
  echo "== launching an $type from Debian 13 ($image), to set up"
else
  image=$ami
  echo "== launching an $type from the base AMI $image"
fi
case $type in
  *.metal | *.metal-*) ;;
  *) echo "inspect.sh: $type is not bare metal (people get metal only: docs/AWS.md)" >&2; exit 2 ;;
esac
market=()
$spot && market=(--instance-market-options 'MarketType=spot,SpotOptions={SpotInstanceType=one-time,InstanceInterruptionBehavior=terminate}')
id=$(aws ec2 run-instances --region "$region" --image-id "$image" --instance-type "$type" \
  --key-name "$key" --security-group-ids "$group" ${market[@]+"${market[@]}"} \
  --iam-instance-profile "Name=$profile" \
  --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=80,VolumeType=gp3,DeleteOnTermination=true}' \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=determinismo-inspect-$bundle},{Key=project,Value=determinismo}]" \
  --query 'Instances[0].InstanceId' --output text)
terminate="aws ec2 terminate-instances --region $region --instance-ids $id"
echo "instance $id (when done: $terminate)"
fail() {
  echo "error: $1" >&2
  if ! $keep; then echo "== terminating $id"; $terminate >/dev/null; fi
  exit 1
}
aws ec2 wait instance-running --region "$region" --instance-ids "$id"
ip=$(aws ec2 describe-instances --region "$region" --instance-ids "$id" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "== waiting for SSH on $ip (10 minutes at most)"
ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5)
waited=0
until ssh "${ssh_opts[@]}" "admin@$ip" true 2>/dev/null; do
  [ "$waited" -lt 600 ] || fail "$ip never answered SSH"
  sleep 10
  waited=$((waited + 10))
done

if [ "$ami" = none ]; then
  echo "== setting it up (setup.sh)"
  "$repo/infra/host/setup.sh" "$ip" --user admin --inspect || fail "setup.sh failed"
  pull="cd ~/determinismo && infra/host/bundle-s3.sh"
else
  # The image loads our KVM at boot (determinismo-kvm.service); its hashes recorded once loaded.
  # SSH answers before the boot ends: waited for the boot first (bounded: 3 minutes).
  ssh "${ssh_opts[@]}" "admin@$ip" 'timeout 180 systemctl is-system-running --wait >/dev/null; systemctl is-active -q determinismo-kvm && test -s /run/determinismo-kvm' \
    || { ssh "${ssh_opts[@]}" "admin@$ip" 'systemctl status --no-pager determinismo-kvm | tail -8' || true
         fail "the image's KVM modules did not load (above)"; }
  pull=bundle-s3.sh
fi

echo "== pulling $bundle from s3://$bucket/$prefix"
ssh "${ssh_opts[@]}" "admin@$ip" "AWS_REGION=$region; export AWS_REGION; $pull pull s3://$bucket/$prefix $bundle ~/store ~/$bundle" \
  || fail "the bundle did not come"

echo "== opening it at its moment"
# The moment, then the command's output (its exec_output events) and the timeline's line.
# Exit 3: a property fails by the moment (a failure's bundle, opened at its failure), as asked.
ssh "${ssh_opts[@]}" "admin@$ip" "cd ~/$bundle && test -x INSPECT.sh && { ./INSPECT.sh 'det-nodes list' > ~/$bundle.first 2>&1 || [ \$? -eq 3 ]; }" \
  || { ssh "${ssh_opts[@]}" "admin@$ip" "tail -20 ~/$bundle.first" || true; fail "INSPECT.sh failed"; }
ssh "${ssh_opts[@]}" "admin@$ip" "grep -a 'at moment\|exec_output\|^\[branch' ~/$bundle.first | cut -c1-240"
echo "== ready: ssh admin@$ip, then cd ~/$bundle && ./INSPECT.sh '<command at the moment>'"
echo "== when done: $terminate"
