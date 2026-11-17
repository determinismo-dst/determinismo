#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# inspect-ami.sh [--key <ec2 key pair>] [--group <security group id>] [--type <instance type>]
#                [--spot] [--keep]
# Builds the inspection AMI: one generic image per release that opens any bundle (a bundle carries
# its guest, system images, the run's own explorer and its checkers' sources; the machine needs
# only our KVM module, the AWS CLI, zstd and podman). Instances launched from it skip setup:
# infra/aws/inspect.sh uses the newest one.
#
# A c8i.xlarge (nested virtualization: setup's hardware check needs VT-x) from Debian 13's AMI is
# set up with setup.sh --inspect, then sealed: what an inspection uses moves to
# /opt/determinismo-inspect (the built kvm.ko and kvm-intel.ko, load-kvm.sh, bundle-s3.sh, and
# the KVM patch they were built from: the modules are GPL, their source goes with them), Elle's
# service image is built once (a bundle's check then finds it cached), and the rest is removed:
# the repository (private), the kernel tree, the toolchain, every authorized SSH key (an instance
# gets its launcher's key from cloud-init) and cloud-init's state (new host keys at each launch).
# Then the image is made (named after the commit), and the builder terminated.
#
# On a bare-metal builder (--type m5zn.metal, --spot to pay its spot price) the same image is the
# base people launch on metal (the samples page: bare metal only, the user's call 2026-11-15),
# named determinismo-base-*: the platform alone (our KVM modules, the bundles' tooling, Elle),
# every sample or failure pulled as a bundle at launch. Metal's one reboot onto the upgraded
# kernel takes about 12 minutes there (bootstrap.sh's bound is 20); an instance launched from the
# image never reboots.
#
# The image's snapshot is a standing cost (EBS snapshot storage, about $0.05 per GB-month for its
# used blocks), as is each copy in another region. Old images: aws ec2 deregister-image, then
# delete their snapshot.
set -euo pipefail
key=determinismo
group=${DETERMINISMO_GROUP:-}
keep=false
type=c8i.xlarge
spot=false
region=${AWS_REGION:-us-east-1}
while [ $# -gt 0 ]; do
  case $1 in
    --key) key=$2; shift 2 ;;
    --group) group=$2; shift 2 ;;
    --type) type=$2; shift 2 ;;
    --spot) spot=true; shift ;;
    --keep) keep=true; shift ;;
    *) echo "inspect-ami.sh: unknown option $1" >&2; exit 2 ;;
  esac
done
[ -n "$group" ] || { echo "inspect-ami.sh: a security group with SSH from you: --group <id> or DETERMINISMO_GROUP" >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
. "$repo/infra/host/commit.sh"
commit=$(commit_of "$repo")
# Metal runs our KVM on the hardware; a virtual size needs nested virtualization for it.
case $type in
  *.metal | *.metal-*) cpu_options=(); role=base ;;
  *) cpu_options=(--cpu-options NestedVirtualization=enabled); role=inspect ;;
esac
market=()
$spot && market=(--instance-market-options 'MarketType=spot,SpotOptions={SpotInstanceType=one-time,InstanceInterruptionBehavior=terminate}')
name=determinismo-$role-$(date -u +%Y%m%d-%H%M)-$commit

echo "== launching the builder ($type$($spot && echo ', spot' || true))"
debian=$(aws ec2 describe-images --region "$region" --owners 136693071363 \
  --filters 'Name=name,Values=debian-13-amd64-*' 'Name=architecture,Values=x86_64' \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)
# 30 GB: the build (kernel tree, toolchain) fits, and an instance from the image gets at least
# this much (inspect.sh asks more for the bundles).
id=$(aws ec2 run-instances --region "$region" --image-id "$debian" --instance-type "$type" \
  --key-name "$key" --security-group-ids "$group" ${cpu_options[@]+"${cpu_options[@]}"} ${market[@]+"${market[@]}"} \
  --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=30,VolumeType=gp3,DeleteOnTermination=true}' \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$name-builder},{Key=project,Value=determinismo}]" \
  --query 'Instances[0].InstanceId' --output text)
terminate="aws ec2 terminate-instances --region $region --instance-ids $id"
echo "builder $id (if this script dies: $terminate)"
finish() {
  if ! $keep; then echo "== terminating the builder $id"; $terminate >/dev/null; fi
}
trap finish EXIT
aws ec2 wait instance-running --region "$region" --instance-ids "$id"
ip=$(aws ec2 describe-instances --region "$region" --instance-ids "$id" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5)
echo "== waiting for SSH on $ip (10 minutes at most)"
waited=0
until ssh "${ssh_opts[@]}" "admin@$ip" true 2>/dev/null; do
  [ "$waited" -lt 600 ] || { echo "error: $ip never answered SSH" >&2; exit 1; }
  sleep 10
  waited=$((waited + 10))
done

echo "== setting it up (setup.sh --inspect)"
"$repo/infra/host/setup.sh" "$ip" --user admin --inspect

# The kernel the image boots, which its KVM modules were built for, and our KVM patch (tags of
# the image: a base is that platform's, whatever runs on it).
kernel=$(ssh "${ssh_opts[@]}" "admin@$ip" uname -r)
kvm_patch=$(cat "$repo"/kernel/patches/*.patch | shasum -a 256 | cut -c1-16)
echo "== sealing it"
ssh "${ssh_opts[@]}" "admin@$ip" 'bash -s' <<'EOF'
set -euo pipefail
cd ~/determinismo
kvm=~/kvm-build/linux-$(uname -r | cut -d+ -f1)/arch/x86/kvm
opt=/opt/determinismo-inspect
sudo install -d "$opt/bin" "$opt/kvm" "$opt/source"
sudo install -m 0644 "$kvm/kvm.ko" "$kvm/kvm-intel.ko" "$opt/kvm/"
sudo install -m 0755 infra/host/load-kvm.sh infra/host/bundle-s3.sh infra/host/nrepl-proxy.py infra/aws/serve-bundle.sh "$opt/bin/"
# The modules' source: the stock kernel's (Debian's linux-source of this version) and our patch.
sudo install -d "$opt/source/kernel/patches" "$opt/source/infra/host"
sudo install -m 0644 kernel/patches/*.patch "$opt/source/kernel/patches/"
sudo install -m 0755 infra/host/build-kvm.sh "$opt/source/infra/host/"
uname -r | sudo tee "$opt/kernel" >/dev/null
sudo tee /etc/systemd/system/determinismo-kvm.service >/dev/null <<UNIT
[Unit]
Description=determinismo's KVM modules (kernel/patches)
After=systemd-modules-load.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$opt/bin/load-kvm.sh $opt/kvm

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable determinismo-kvm.service >/dev/null
sudo ln -sf "$opt/bin/bundle-s3.sh" /usr/local/bin/bundle-s3.sh
# A REPL in a node at the bundle's moment, for an editor through an SSH tunnel (--bundle).
sudo ln -sf "$opt/bin/nrepl-proxy.py" /usr/local/bin/nrepl-proxy.py
# serve's UI for a bundle (a stack's unit runs it; the stack fetches this release's over it).
sudo ln -sf "$opt/bin/serve-bundle.sh" /usr/local/bin/serve-bundle.sh
# Elle's service image, built as a bundle's check builds it (from its checkers/: the same
# Dockerfile and sources hit this cache, so its first check starts in seconds).
podman build -q -t determinismo-elle -f checkers/elle/Dockerfile . >/dev/null
echo "elle image: $(podman image inspect determinismo-elle --format '{{.Id}}' | cut -c1-12)"
# ...and started at every boot (a quadlet of admin's, lingering): a check finds the service of
# its version answering and builds nothing. Podman's build cache does not carry over (a bundle's
# checkers/ come from S3 with new times: the image's own build took 45 s again, 2026-11-10). A
# bundle of another Elle version replaces it as on any host (podman rm -f, then its own run), so
# the unit never restarts it.
mkdir -p ~/.config/containers/systemd
cat > ~/.config/containers/systemd/determinismo-elle.container <<'QUADLET'
[Unit]
Description=Elle's service for bundles' host checks (port 7700)

[Container]
Image=localhost/determinismo-elle:latest
ContainerName=determinismo-elle
Network=host

[Service]
Restart=no

[Install]
WantedBy=default.target
QUADLET
sudo loginctl enable-linger "$USER"
systemctl --user daemon-reload
systemctl --user start determinismo-elle.service
for _ in $(seq 1 60); do curl -fsS -m 2 http://127.0.0.1:7700/version 2>/dev/null && break; sleep 2; done
echo " (elle answering at boot)"
systemctl --user stop determinismo-elle.service
# What an inspection never uses, and what must not leave with the image.
cd ~
rm -rf ~/determinismo ~/kvm-build ~/opt ~/.cache ~/.zig-cache ~/.local/share/zig ~/guest
rm -f ~/.bash_history ~/.ssh/authorized_keys ~/.ssh/known_hosts
sudo rm -f /root/.ssh/authorized_keys /root/.bash_history
sudo apt-get clean
sudo cloud-init clean --logs --machine-id
sudo fstrim -av >/dev/null
echo "sealed: $(du -sh $opt | cut -f1) in $opt; $(df -h / | awk 'NR==2 {print $3}') used"
EOF

echo "== making the image $name"
ami=$(aws ec2 create-image --region "$region" --instance-id "$id" --name "$name" \
  --description "determinismo $role machine ($commit, built on $type): opens bundles (docs/INSPECT.md)" \
  --tag-specifications "ResourceType=image,Tags=[{Key=project,Value=determinismo},{Key=role,Value=$role},{Key=commit,Value=$commit},{Key=kernel,Value=$kernel},{Key=kvm-patch,Value=$kvm_patch}]" \
  "ResourceType=snapshot,Tags=[{Key=project,Value=determinismo},{Key=role,Value=$role},{Key=commit,Value=$commit}]" \
  --query ImageId --output text)
echo "image $ami: waiting until available (bounded: 30 minutes)"
waited=0
until [ "$(aws ec2 describe-images --region "$region" --image-ids "$ami" --query 'Images[0].State' --output text)" = available ]; do
  [ "$waited" -lt 1800 ] || { echo "error: $ami not available after 30 minutes" >&2; exit 1; }
  sleep 20
  waited=$((waited + 20))
done
snapshot=$(aws ec2 describe-images --region "$region" --image-ids "$ami" \
  --query 'Images[0].BlockDeviceMappings[0].Ebs.SnapshotId' --output text)
echo "== $ami ready ($name, snapshot $snapshot): infra/aws/inspect.sh uses it"
