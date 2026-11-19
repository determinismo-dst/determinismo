// SPDX-License-Identifier: MIT
//! Imports Kubernetes manifests as a profile (`explore --kubernetes <manifests directory>`), as
//! Antithesis runs them (docs: setup/kubernetes): a single-node K3s cluster, with CoreDNS and the
//! local-path storage class, without Traefik, ServiceLB or metrics-server, in one privileged node
//! named `kubernetes`. The guest has no network, so the node's image holds K3s's air-gap images
//! and every image the manifests name (fully qualified, as Antithesis asks), which K3s imports as
//! it starts.
//!
//! Antithesis deploys the manifests with kapp (a logical order, then waits until they are
//! ready); here the scenario's first command does it (`ready_path`): it applies them until all
//! of them apply and waits until every Deployment, StatefulSet and DaemonSet is rolled out and
//! every running pod is ready. setup_complete follows it.
//!
//! Every container gets what Antithesis gives every container, whoever made its pod (a
//! Deployment, a bare Pod, an operator: CloudNativePG's PostgreSQL instances): the node starts
//! (`start_path`) by making containerd's default spec the base of its runc runtime (every
//! container's) with libvoidstar, its device, the coverage bitmaps and the SDK's output added
//! (det-kubespec; `containerd_dropin`, in the directory K3s's configuration imports), then runs
//! K3s.
//!
//! Test templates may be in any container (/opt/antithesis/test/v1/<template>/): each one found
//! in an image the manifests name gets a wrapper at the same path in the node, which runs it in
//! a running container of that image through kubectl exec.
const std = @import("std");
const assert = std.debug.assert;

pub const node_name = "kubernetes";
pub const k3s_image = "docker.io/rancher/k3s:v1.36.6-k3s1";
const airgap_url = "https://github.com/k3s-io/k3s/releases/download/v1.36.6%2Bk3s1/" ++
    "k3s-airgap-images-amd64.tar.zst";
/// Outside /opt/determinismo, which a node gets from the runner (read-only, over the image's).
pub const tools_directory = "/opt/determinismo-kubernetes";
pub const ready_path = tools_directory ++ "/ready";
/// The node's entrypoint: the containers' base spec, then K3s (`start_script`).
pub const start_path = tools_directory ++ "/start";
pub const entrypoint = [_][]const u8{ "/bin/sh", start_path };
/// A file of containerd's configuration that K3s's imports (its template's `imports`: the
/// template directory's config-v3.toml.d/*.toml), merged over K3s's own.
pub const containerd_dropin_path = "/var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.d/determinismo.toml";
const base_spec_path = tools_directory ++ "/base-spec.json";
/// K3s's containerd root: its images and containers' layers.
const containerd_root = "/var/lib/rancher/k3s/agent/containerd";
const exec_path = tools_directory ++ "/exec";
pub const manifests_directory = tools_directory ++ "/manifests";
pub const command = [_][]const u8{
    "server",
    "--disable=traefik,servicelb,metrics-server",
    "--disable-cloud-controller",
    "--disable-helm-controller",
    "--write-kubeconfig-mode=644",
};
pub const kubeconfig = "KUBECONFIG=/etc/rancher/k3s/k3s.yaml";
pub const api_port = 6443;
const images_max = 64;

/// The images a manifest names (its `image:` fields, YAML or JSON), each once, added to
/// `images` in order.
pub fn images_note(arena: std.mem.Allocator, manifest: []const u8, images: *std.ArrayList([]const u8)) !void {
    var lines = std.mem.tokenizeAny(u8, manifest, "\r\n");
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t");
        if (std.mem.startsWith(u8, line, "- ")) line = std.mem.trimStart(u8, line[2..], " ");
        const key = if (std.mem.startsWith(u8, line, "image:"))
            "image:".len
        else if (std.mem.startsWith(u8, line, "\"image\":"))
            "\"image\":".len
        else
            continue;
        var value = std.mem.trim(u8, line[key..], " \t,");
        if (std.mem.indexOf(u8, value, " #")) |comment| value = std.mem.trimEnd(u8, value[0..comment], " ");
        value = std.mem.trim(u8, value, "\"'");
        if (value.len == 0) continue;
        value = try normalized(arena, value);
        for (images.items) |known| {
            if (std.mem.eql(u8, known, value)) break;
        } else {
            if (images.items.len == images_max) return error.TooManyImages;
            try images.append(arena, try arena.dupe(u8, value));
        }
    }
}

/// The images of a comma-separated list (explore's --images) added to `images`, each once.
pub fn images_add(arena: std.mem.Allocator, list: []const u8, images: *std.ArrayList([]const u8)) !void {
    var listed = std.mem.tokenizeScalar(u8, list, ',');
    while (listed.next()) |raw| {
        var value = std.mem.trim(u8, raw, " ");
        if (value.len == 0) continue;
        value = try normalized(arena, value);
        for (images.items) |known| {
            if (std.mem.eql(u8, known, value)) break;
        } else {
            if (images.items.len == images_max) return error.TooManyImages;
            try images.append(arena, try arena.dupe(u8, value));
        }
    }
}

test images_add {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var images: std.ArrayList([]const u8) = .empty;
    // ParadeDB's: its Cluster names PostgreSQL's image as `imageName:`, the launch lists it.
    try images_note(arena, "  imageName: registry.example/paradedb:18-abc\n  image: docker.io/library/postgres:18\n", &images);
    try std.testing.expectEqual(@as(usize, 1), images.items.len);
    try images_add(arena, "registry.example/paradedb:18-abc, docker.io/library/postgres:18", &images);
    try std.testing.expectEqual(@as(usize, 2), images.items.len); // The known one once.
    try std.testing.expectEqualStrings("registry.example/paradedb:18-abc", images.items[1]);
}

/// A reference as containerd's CRI looks it up (Docker's normalization): Docker Hub's
/// `docker.io/<name>` (or `index.docker.io/`) with one path component is
/// `docker.io/library/<name>`. The images' archives are named so: containerd names an image by
/// its archive's name as written, and a pod's `docker.io/postgres:18` finds
/// `docker.io/library/postgres:18` only.
pub fn normalized(arena: std.mem.Allocator, reference: []const u8) ![]const u8 {
    for ([_][]const u8{ "docker.io/", "index.docker.io/" }) |hub| {
        if (!std.mem.startsWith(u8, reference, hub)) continue;
        const rest = reference[hub.len..];
        const path = rest[0 .. std.mem.indexOfAny(u8, rest, ":@") orelse rest.len];
        const library = std.mem.indexOfScalar(u8, path, '/') == null;
        return std.fmt.allocPrint(arena, "docker.io/{s}{s}", .{ if (library) "library/" else "", rest });
    }
    return reference;
}

/// Antithesis asks for fully qualified references (registry, name and tag or digest): the
/// guest pulls nothing, so a reference must name an image K3s imported (normalized).
pub fn qualified(reference: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, reference, '/') orelse return false;
    const registry = reference[0..slash];
    const domain = std.mem.indexOfAny(u8, registry, ".:") != null or std.mem.eql(u8, registry, "localhost");
    const name = reference[slash + 1 ..];
    const tagged = std.mem.indexOfScalar(u8, name, ':') != null or std.mem.indexOfScalar(u8, name, '@') != null;
    return domain and tagged;
}

/// How the workload's images reach K3s (part of the node's hash: another format, another node).
pub const images_format = "images/<n>.tar: OCI archives of zstd layers";

/// The node image's Dockerfile: K3s, its air-gap images, the workload's images (images/, an OCI
/// archive each, when there are any), and determinismo's tools and the templates' wrappers.
pub fn dockerfile(arena: std.mem.Allocator, with_images: bool, with_templates: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "FROM {s}\nADD {s} /var/lib/rancher/k3s/agent/images/\n", .{ k3s_image, airgap_url });
    if (with_images) try out.appendSlice(arena, "COPY images/ /var/lib/rancher/k3s/agent/images/\n");
    try out.print(arena, "COPY determinismo-kubernetes/ {s}/\n", .{tools_directory});
    if (with_templates) try out.appendSlice(arena, "COPY antithesis/ /opt/antithesis/\n");
    return out.items;
}

/// The node's start (`start_path`): containerd's default spec with what Antithesis gives every
/// container (det-kubespec) as the base of the runtime K3s makes every container with, then K3s
/// with the node's command.
pub const start_script =
    \\#!/bin/sh
    \\# determinismo's start of an imported Kubernetes cluster's node (kubernetes.zig): every
    \\# container K3s makes gets libvoidstar, its device, the coverage bitmaps and the SDK's
    \\# output, as Antithesis gives every container, then K3s itself.
    \\set -e
    \\# containerd's images and containers on a tmpfs of their own, where its overlayfs snapshotter
    \\# works (not on the node's root, an overlay itself): native, which copies every layer whole,
    \\# filled the node with ParadeDB's images (kubelet's DiskPressure evicted CloudNativePG's
    \\# operator). As large as the guest's memory: what is there is what the images hold.
    \\mkdir -p
++ " " ++ containerd_root ++ "\n" ++
    \\mount -t tmpfs -o size=100% tmpfs
++ " " ++ containerd_root ++ "\n" ++
    \\mkdir -p
++ " " ++ std.fs.path.dirname(containerd_dropin_path).? ++ "\n" ++
    \\cp
++ " " ++ tools_directory ++ "/determinismo.toml " ++ containerd_dropin_path ++ "\n" ++
    \\ctr oci spec | /opt/determinismo/bin/det-kubespec >
++ " " ++ base_spec_path ++ "\n" ++
    \\exec k3s "$@"
    \\
;

/// What containerd's configuration gets over K3s's (`containerd_dropin_path`): its runc runtime,
/// the one every container runs with, starts each from the base spec start_script makes.
/// (A runtime of its own cannot be K3s's default: K3s takes only the runtimes it finds, crun's
/// and nvidia's, as --default-runtime.)
pub const containerd_dropin =
    \\version = 3
    \\
    \\[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc]
    \\  base_runtime_spec = "
++ base_spec_path ++
    \\"
    \\
;

/// The setup command (the node's `ready_path`): kapp's deploy, as a script.
pub const ready_script =
    \\#!/bin/sh
    \\# determinismo's setup for imported Kubernetes manifests (kubernetes.zig): applied until all
    \\# of them apply (a namespace or a custom resource definition before what needs it), then
    \\# every Deployment, StatefulSet and DaemonSet rolled out, every running pod ready, and the
    \\# manifests' own Pods running and ready (or done).
    \\export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    \\# The pods' output as events, each line named after its pod (det-podlogs detaches itself).
    \\/opt/determinismo/bin/det-podlogs
    \\manifests=
++ manifests_directory ++
    \\
    \\timeout=600s
    \\attempts=0
    \\until kubectl get --raw /readyz > /dev/null 2>&1; do
    \\  attempts=$((attempts + 1))
    \\  [ $attempts -le 600 ] || { echo "the API server never answered"; exit 1; }
    \\  sleep 1
    \\done
    \\attempts=0
    \\# Created, as kapp creates what is new: no last-applied copy (kubectl apply's annotation of it
    \\# is limited to 256 KiB, and CloudNativePG's poolers CRD is larger: "metadata.annotations: Too
    \\# long", the operator never ready, its webhook refusing the Cluster), and the null fields a
    \\# Helm render leaves pruned (server-side apply refused ParadeDB's Cluster for its empty
    \\# `externalClusters:`). Again until every object is there: a custom resource after its CRD,
    \\# one an operator's webhook admits after the operator.
    \\until kubectl get --recursive --filename $manifests > /dev/null 2>&1; do
    \\  attempts=$((attempts + 1))
    \\  [ $attempts -le 60 ] || { echo "the manifests never applied"; exit 1; }
    \\  kubectl create --recursive --filename $manifests 2>&1 | grep -v AlreadyExists
    \\  sleep 2
    \\done
    \\listed='{{range .items}}{{.metadata.namespace}} {{.metadata.name}}{{"\n"}}{{end}}'
    \\for kind in deployment statefulset daemonset; do
    \\  kubectl get $kind --all-namespaces --output go-template="$listed" > /tmp/workload || exit 1
    \\  while read namespace name; do
    \\    kubectl rollout status $kind/$name --namespace $namespace --timeout $timeout || exit 1
    \\  done < /tmp/workload
    \\done
    \\kubectl wait pod --all --all-namespaces --for condition=Ready --field-selector status.phase=Running \
    \\  --timeout $timeout > /dev/null
    \\# The manifests' own Pods (no owner: an operator's have theirs), as kapp waits for the Pods it
    \\# applies: Running and Ready, or Succeeded (kapp has no rule for custom resources by default:
    \\# a CloudNativePG Cluster is applied, not awaited).
    \\bare='{{range .items}}{{if not .metadata.ownerReferences}}{{.metadata.namespace}} {{.metadata.name}}{{"\n"}}{{end}}{{end}}'
    \\kubectl get pods --all-namespaces --output go-template="$bare" > /tmp/bare || exit 1
    \\while read namespace name; do
    \\  attempts=0
    \\  until state=$(kubectl get pod $name --namespace $namespace --output \
    \\      jsonpath='{.status.phase} {.status.conditions[?(@.type=="Ready")].status}') && \
    \\      { [ "$state" = "Running True" ] || [ "${state%% *}" = Succeeded ]; }; do
    \\    attempts=$((attempts + 1))
    \\    [ $attempts -le 600 ] || { echo "pod $namespace/$name never became ready ($state)"; exit 1; }
    \\    sleep 1
    \\  done
    \\done < /tmp/bare
    \\
;

/// Runs a test command in a running container of an image (the first, by namespace and name).
pub const exec_script =
    \\#!/bin/sh
    \\# exec <image> <command> [arguments...]: an Antithesis test command found in <image>, run in
    \\# a running container of it (kubernetes.zig).
    \\export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    \\image="$1"
    \\shift
    \\listed='{{range .items}}{{$pod := .}}{{range .spec.containers}}{{$pod.metadata.namespace}} {{$pod.metadata.name}} {{.name}} {{.image}}{{"\n"}}{{end}}{{end}}'
    \\kubectl get pods --all-namespaces --field-selector status.phase=Running --output go-template="$listed" > /tmp/containers.$$ || exit 1
    \\target=""
    \\while read namespace pod container running; do
    \\  if [ "$running" = "$image" ]; then target="$namespace $pod $container"; break; fi
    \\done < /tmp/containers.$$
    \\rm -f /tmp/containers.$$
    \\[ -n "$target" ] || { echo "no running container of $image" >&2; exit 1; }
    \\set -- $target "$@"
    \\namespace="$1" pod="$2" container="$3"
    \\shift 3
    \\exec kubectl exec --namespace "$namespace" "$pod" --container "$container" -- "$@"
    \\
;

/// A test template's wrapper in the node, at the template's path: runs it in its image's pod.
pub fn wrapper(arena: std.mem.Allocator, image: []const u8, path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "#!/bin/sh\nexec {s} {s} {s} \"$@\"\n", .{
        exec_path, try shell_quote(arena, image), try shell_quote(arena, path),
    });
}

fn shell_quote(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var quoted: std.ArrayList(u8) = .empty;
    try quoted.append(arena, '\'');
    for (text) |byte| {
        if (byte == '\'') try quoted.appendSlice(arena, "'\\''") else try quoted.append(arena, byte);
    }
    try quoted.append(arena, '\'');
    return quoted.items;
}

test images_note {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var images: std.ArrayList([]const u8) = .empty;
    const manifest =
        \\apiVersion: apps/v1
        \\kind: Deployment
        \\spec:
        \\  template:
        \\    spec:
        \\      containers:
        \\        - name: redis
        \\          image: docker.io/library/redis:7.4-alpine  # the server
        \\          imagePullPolicy: IfNotPresent
        \\        - image: "localhost/client:1"
        \\          name: client
        \\---
        \\{"spec": {"containers": [{"name": "x"}]}, "image": "docker.io/library/redis:7.4-alpine"}
        \\
    ;
    try images_note(arena, manifest, &images);
    try std.testing.expectEqual(@as(usize, 2), images.items.len);
    try std.testing.expectEqualStrings("docker.io/library/redis:7.4-alpine", images.items[0]);
    try std.testing.expectEqualStrings("localhost/client:1", images.items[1]);
    // Docker Hub's short form as containerd's CRI looks it up (ParadeDB's publisher names
    // docker.io/postgres:18): the archive named so, and one image under either spelling.
    try images_note(arena, "image: docker.io/postgres:18\nimage: index.docker.io/team/app:2\nimage: docker.io/redis:7.4-alpine\n", &images);
    try std.testing.expectEqual(@as(usize, 4), images.items.len);
    try std.testing.expectEqualStrings("docker.io/library/postgres:18", images.items[2]);
    try std.testing.expectEqualStrings("docker.io/team/app:2", images.items[3]);
}

test qualified {
    try std.testing.expect(qualified("docker.io/library/redis:7.4-alpine"));
    try std.testing.expect(qualified("localhost/client:1"));
    try std.testing.expect(qualified("registry:5000/team/app@sha256:abcd"));
    try std.testing.expect(!qualified("redis:7.4"));
    try std.testing.expect(!qualified("library/redis:7.4"));
    try std.testing.expect(!qualified("docker.io/library/redis"));
}

test wrapper {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const text = try wrapper(arena_state.allocator(), "localhost/client:1", "/opt/antithesis/test/v1/x/it's");
    try std.testing.expectEqualStrings("#!/bin/sh\nexec /opt/determinismo-kubernetes/exec " ++
        "'localhost/client:1' '/opt/antithesis/test/v1/x/it'\\''s' \"$@\"\n", text);
}

test start_script {
    try std.testing.expect(std.mem.indexOf(u8, start_script, "\nmount -t tmpfs -o size=100% tmpfs " ++ containerd_root ++ "\n") != null);
    for (command) |argument| try std.testing.expect(!std.mem.startsWith(u8, argument, "--snapshotter"));
    try std.testing.expect(std.mem.indexOf(u8, start_script, "\nctr oci spec | /opt/determinismo/bin/det-kubespec > " ++
        tools_directory ++ "/base-spec.json\nexec k3s \"$@\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, containerd_dropin, "runtimes.runc]\n  base_runtime_spec = \"" ++ base_spec_path ++ "\"\n") != null);
    // The pods' SDK output is the base spec's now: no Deployment patched (and restarted) for it.
    try std.testing.expect(std.mem.indexOf(u8, ready_script, "kubectl patch") == null);
}

test ready_script {
    try std.testing.expect(std.mem.indexOf(u8, ready_script, "\nmanifests=" ++ manifests_directory ++ "\ntimeout=600s\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, ready_script, "until kubectl get --recursive --filename $manifests > /dev/null 2>&1; do\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, ready_script, "kubectl create --recursive --filename $manifests 2>&1 | grep -v AlreadyExists\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, ready_script, "\nuntil kubectl apply") == null);
}
