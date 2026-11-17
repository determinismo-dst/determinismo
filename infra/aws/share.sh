#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# share.sh: bundles handed to people outside this account (docs/INSPECT.md).
#
#   share.sh grant <account id> <bundle>...   their account may open these bundles: the bucket's
#       policy lets it list and read each bundle's own files and the store's blobs, and the
#       newest inspection AMI (inspect-ami.sh) is shared with it. Prints what they run.
#   share.sh revoke <account id> [<bundle>...]   takes those bundles back (all of the account's,
#       and the AMI's launch permission, when none is named).
#   share.sh list   who may open what.
#   share.sh links <bundle> [--hours N]   for someone without AWS: a script (on standard output)
#       that downloads the bundle and its blobs through presigned links, valid N hours (default
#       24; links signed with temporary credentials, such as `aws login`'s, end with them).
#
# Blobs (sha256/<hex>) are readable by a granted account whole: a blob's name is its content's
# digest, so only someone who has a bundle's STORED (which names its blobs) can ask for one, and
# the policy stays small (one statement per bundle, under S3's 20 KB policy limit).
#
# Options: --bucket <name> (or DETERMINISMO_BUCKET), --prefix <prefix> (determinismo).
set -euo pipefail
bucket=${DETERMINISMO_BUCKET:-}
prefix=determinismo
hours=24
region=${AWS_REGION:-us-east-1}
args=()
while [ $# -gt 0 ]; do
  case $1 in
    --bucket) bucket=$2; shift 2 ;;
    --prefix) prefix=$2; shift 2 ;;
    --hours) hours=$2; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]}"
usage() {
  sed -n '3,20p' "$0" >&2
  exit 2
}
[ $# -ge 1 ] || usage
[ -n "$bucket" ] || { echo "share.sh: the bundles' bucket: --bucket <name> or DETERMINISMO_BUCKET" >&2; exit 2; }
command -v aws >/dev/null || { echo "share.sh: the AWS CLI (aws) is not installed" >&2; exit 1; }

policy_get() {
  aws s3api get-bucket-policy --bucket "$bucket" --query Policy --output text 2>/dev/null \
    || echo '{"Version":"2012-10-17","Statement":[]}'
}
policy_put() {
  local policy=$1
  if [ "$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])["Statement"]))' "$policy")" = 0 ]; then
    aws s3api delete-bucket-policy --bucket "$bucket"
  else
    aws s3api put-bucket-policy --bucket "$bucket" --policy "$policy"
  fi
}
newest_ami() {
  aws ec2 describe-images --region "$region" --owners self \
    --filters 'Name=name,Values=determinismo-inspect-*' 'Name=state,Values=available' \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text
}

# The policy edited by a small Python program: statements named share-<account>-<bundle>.
edit='
import json, re, sys
policy = json.loads(sys.argv[1])
action, bucket, prefix, account = sys.argv[2:6]
bundles = sys.argv[6:]
def sid(bundle):
    return "share" + account + re.sub(r"[^A-Za-z0-9]", "", bundle)
mine = lambda s: s.get("Sid", "").startswith("share" + account)
if action == "grant":
    wanted = {sid(b) for b in bundles}
    policy["Statement"] = [s for s in policy["Statement"] if s.get("Sid") not in wanted
                           and s.get("Sid") != "share" + account + "blobs"]
    principal = {"AWS": "arn:aws:iam::%s:root" % account}
    for b in bundles:
        policy["Statement"].append({
            "Sid": sid(b), "Effect": "Allow", "Principal": principal,
            "Action": "s3:ListBucket", "Resource": "arn:aws:s3:::%s" % bucket,
            "Condition": {"StringLike": {"s3:prefix": ["%s/bundles/%s/*" % (prefix, b), "%s/bundles/%s" % (prefix, b)]}}})
        policy["Statement"].append({
            "Sid": sid(b) + "files", "Effect": "Allow", "Principal": principal,
            "Action": "s3:GetObject", "Resource": "arn:aws:s3:::%s/%s/bundles/%s/*" % (bucket, prefix, b)})
    policy["Statement"].append({
        "Sid": "share" + account + "blobs", "Effect": "Allow", "Principal": principal,
        "Action": "s3:GetObject", "Resource": "arn:aws:s3:::%s/%s/sha256/*" % (bucket, prefix)})
elif action == "revoke":
    if bundles:
        gone = {sid(b) for b in bundles} | {sid(b) + "files" for b in bundles}
        policy["Statement"] = [s for s in policy["Statement"] if s.get("Sid") not in gone]
        if not any(mine(s) and not s["Sid"].endswith("blobs") for s in policy["Statement"]):
            policy["Statement"] = [s for s in policy["Statement"] if not mine(s)]
    else:
        policy["Statement"] = [s for s in policy["Statement"] if not mine(s)]
print(json.dumps(policy))
'

case $1 in
  grant)
    [ $# -ge 3 ] || usage
    account=$2
    shift 2
    for bundle in "$@"; do
      aws s3api head-object --bucket "$bucket" --key "$prefix/bundles/$bundle/STORED" >/dev/null 2>&1 \
        || { echo "share.sh: no bundle $bundle in s3://$bucket/$prefix" >&2; exit 1; }
    done
    policy_put "$(python3 -c "$edit" "$(policy_get)" grant "$bucket" "$prefix" "$account" "$@")"
    ami=$(newest_ami)
    if [ "$ami" != None ]; then
      aws ec2 modify-image-attribute --region "$region" --image-id "$ami" \
        --launch-permission "Add=[{UserId=$account}]"
      echo "share.sh: $account may launch $ami (the inspection AMI, in $region)"
    else
      echo "share.sh: no inspection AMI to share (inspect-ami.sh); they set up with setup.sh --inspect" >&2
    fi
    echo "share.sh: $account may open: $*"
    cat <<EOF

What they need in their account ($account), once:
- an instance profile whose role EC2 may assume, with this policy:
  {"Version":"2012-10-17","Statement":[
    {"Effect":"Allow","Action":"s3:ListBucket","Resource":"arn:aws:s3:::$bucket"},
    {"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::$bucket/$prefix/*"}]}
- a key pair and a security group letting their address in on SSH.
Then, for each bundle (infra/aws/inspect.sh, or by hand from the AMI):
EOF
    for bundle in "$@"; do
      echo "  inspect.sh $bundle --bucket $bucket --prefix $prefix --profile <theirs> --key <theirs> --group <theirs>"
    done
    ;;
  revoke)
    [ $# -ge 2 ] || usage
    account=$2
    shift 2
    policy_put "$(python3 -c "$edit" "$(policy_get)" revoke "$bucket" "$prefix" "$account" "$@")"
    if [ $# -eq 0 ]; then
      for ami in $(aws ec2 describe-images --region "$region" --owners self \
          --filters 'Name=name,Values=determinismo-inspect-*' --query 'Images[].ImageId' --output text); do
        aws ec2 modify-image-attribute --region "$region" --image-id "$ami" \
          --launch-permission "Remove=[{UserId=$account}]"
      done
      echo "share.sh: $account may open nothing, nor launch the inspection AMIs"
    else
      echo "share.sh: $account may no longer open: $*"
    fi
    ;;
  list)
    policy_get | python3 -c '
import json, sys
for s in json.load(sys.stdin)["Statement"]:
    if s.get("Sid", "").startswith("share") and s["Action"] == "s3:ListBucket":
        print(s["Principal"]["AWS"].split(":")[4], s["Condition"]["StringLike"]["s3:prefix"][1].split("/")[-1])'
    for ami in $(aws ec2 describe-images --region "$region" --owners self \
        --filters 'Name=name,Values=determinismo-inspect-*' --query 'Images[].ImageId' --output text); do
      echo "$ami launchable by: $(aws ec2 describe-image-attribute --region "$region" --image-id "$ami" \
        --attribute launchPermission --query 'LaunchPermissions[].UserId' --output text)"
    done
    ;;
  links)
    [ $# -eq 2 ] || usage
    bundle=$2
    seconds=$((hours * 3600))
    remote=s3://$bucket/$prefix
    files=$(aws s3 ls --recursive "$remote/bundles/$bundle/" | awk '{print $4}')
    [ -n "$files" ] || { echo "share.sh: no bundle $bundle in $remote" >&2; exit 1; }
    stored=$(aws s3 cp --quiet "$remote/bundles/$bundle/STORED" -)
    echo "#!/usr/bin/env bash"
    echo "# $bundle: downloads it into ./$bundle and its blobs into ./store (links valid until $(date -u -v+"${hours}"H +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -d "+$hours hours" +%Y-%m-%dT%H:%MZ)),"
    echo "# then puts each blob where the bundle names it (its own explorer, checked against its digest)."
    echo "# Then: cd $bundle && ./INSPECT.sh '<command at the moment>' (an Intel host with our KVM: docs/INSPECT.md)."
    echo "set -euo pipefail"
    echo "mkdir -p $bundle store/sha256"
    for key in $files; do
      path=${key#"$prefix/bundles/$bundle/"}
      echo "mkdir -p \"$bundle/$(dirname "$path")\" && curl -fsS -o \"$bundle/$path\" '$(aws s3 presign "s3://$bucket/$key" --expires-in "$seconds" --region "$region")'"
    done
    while read -r hex _size _path; do
      echo "[ -f store/sha256/$hex ] || curl -fsS -o store/sha256/$hex '$(aws s3 presign "$remote/sha256/$hex" --expires-in "$seconds" --region "$region")'"
    done <<<"$stored"
    explorer=$(awk '$3 ~ /^artifacts\/[0-9a-f]+-determinismo$/ { print $1 }' <<<"$stored")
    echo "chmod +x $bundle/INSPECT.sh store/sha256/$explorer"
    echo "store/sha256/$explorer bundle fetch $bundle store"
    echo "for f in $bundle/artifacts/*; do [ \"\$(head -c 4 \"\$f\" | od -An -c | tr -d ' ')\" = '177ELF' ] && chmod +x \"\$f\"; done"
    echo "echo \"$bundle ready: cd $bundle && ./INSPECT.sh '<command at the moment>'\""
    ;;
  *) usage ;;
esac
