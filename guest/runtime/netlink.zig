// SPDX-License-Identifier: MIT
//! The few rtnetlink requests the node runtime needs: veth pairs created straight into two
//! network namespaces, IPv4 addresses, host routes, and links up or down. One request at a time,
//! acknowledged before the next, from a fixed buffer.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

const message_size_max = 1024;
const flag_request: u16 = 0x1;
const flag_ack: u16 = 0x4;
const flag_exclusive: u16 = 0x200;
const flag_create: u16 = 0x400;
const message_error: u16 = 2;
const rtm_newlink: u16 = 16;
const rtm_dellink: u16 = 17;
const rtm_newaddr: u16 = 20;
const rtm_newroute: u16 = 24;
const rtm_delroute: u16 = 25;
const rtm_newqdisc: u16 = 36;
const rtm_delqdisc: u16 = 37;
const rtm_getqdisc: u16 = 38;
const flag_dump: u16 = 0x300;
const message_done: u16 = 3;
const flag_replace: u16 = 0x100;
const tca_kind: u16 = 1;
const tca_options: u16 = 2;
const tca_netem_reorder: u16 = 3;
const tca_netem_corrupt: u16 = 4;
const tca_netem_loss: u16 = 5;
const tca_netem_rate: u16 = 6;
/// TCA_NETEM_LOSS's nested model: Gilbert-Elliott (struct tc_netem_gemodel: p, r, h, k1).
const netem_loss_ge: u16 = 2;
const tca_netem_latency64: u16 = 10;
const tca_netem_jitter64: u16 = 11;
const tca_netem_prng_seed: u16 = 14;
const tc_handle_root: u32 = 0xffff_ffff;
const tc_handle_netem: u32 = 0x1_0000; // 1:0
const tcmsg_size = 20;
const netem_limit_packets = 10_000;
const ifla_address: u16 = 1;
const ifla_ifname: u16 = 3;
const ifla_linkinfo: u16 = 18;
const ifla_net_ns_pid: u16 = 19;
const ifla_info_kind: u16 = 1;
const ifla_info_data: u16 = 2;
const veth_info_peer: u16 = 1;
const ifa_address: u16 = 1;
const ifa_local: u16 = 2;
const rta_destination: u16 = 1;
const rta_output_interface: u16 = 4;
const rta_gateway: u16 = 5;
const iff_up: u32 = 1;
const ifinfo_size = 16;
const header_size = 16;
const siocgifindex: u32 = 0x8933;
pub const interface_name_size_max = 15;

pub const Address = [4]u8;
pub const LinkState = enum { up, down };

/// A connection to the kernel's routing subsystem in the calling thread's network namespace.
pub const Socket = struct {
    fd: linux.fd_t,
    sequence: u32 = 0,

    pub fn open() !Socket {
        const result = linux.socket(linux.AF.NETLINK, linux.SOCK.RAW | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(result) != .SUCCESS) return error.NetlinkSocket;
        return .{ .fd = @intCast(result) };
    }

    pub fn close(socket: *Socket) void {
        assert(socket.fd >= 0);
        _ = linux.close(socket.fd);
        socket.* = undefined;
    }

    /// A veth pair: `name` in the network namespace of process `pid`, `peer_name` in that of
    /// `peer_pid`.
    pub fn veth_create(socket: *Socket, ends: [2]VethEnd) !void {
        var message: Message = .init(rtm_newlink, flag_create | flag_exclusive);
        message.append_bytes(&@as([ifinfo_size]u8, @splat(0)));
        ends[0].append(&message);
        const link_info = message.nest_begin(ifla_linkinfo);
        message.attribute(ifla_info_kind, "veth");
        const info_data = message.nest_begin(ifla_info_data);
        const peer = message.nest_begin(veth_info_peer);
        message.append_bytes(&@as([ifinfo_size]u8, @splat(0)));
        ends[1].append(&message);
        message.nest_end(peer);
        message.nest_end(info_data);
        message.nest_end(link_info);
        try socket.send(&message);
    }

    /// Removes the interface (both ends, for a veth); nothing when there is none.
    pub fn link_delete(socket: *Socket, name: []const u8) !void {
        const interface = socket.index(name) catch return; // Already gone.
        var message: Message = .init(rtm_dellink, 0);
        var info: [ifinfo_size]u8 = @splat(0);
        std.mem.writeInt(i32, info[4..8], interface, .little);
        message.append_bytes(&info);
        socket.send(&message) catch |err| switch (err) {
            error.NetlinkRequestFailed => {}, // Gone meanwhile.
            else => return err,
        };
    }

    pub fn link_set(socket: *Socket, name: []const u8, state: LinkState) !void {
        var message: Message = .init(rtm_newlink, 0);
        var info: [ifinfo_size]u8 = @splat(0);
        std.mem.writeInt(i32, info[4..8], try socket.index(name), .little);
        std.mem.writeInt(u32, info[8..12], if (state == .up) iff_up else 0, .little);
        std.mem.writeInt(u32, info[12..16], iff_up, .little); // Change only IFF_UP.
        message.append_bytes(&info);
        try socket.send(&message);
    }

    /// `address`/32 on the interface: every link of a node carries the node's one address.
    pub fn address_add(socket: *Socket, name: []const u8, address: Address) !void {
        var message: Message = .init(rtm_newaddr, flag_create | flag_exclusive);
        var info: [8]u8 = .{ linux.AF.INET, 32, 0, 0, 0, 0, 0, 0 };
        std.mem.writeInt(u32, info[4..8], @intCast(try socket.index(name)), .little);
        message.append_bytes(&info);
        message.attribute(ifa_local, &address);
        message.attribute(ifa_address, &address);
        try socket.send(&message);
    }

    /// A host route: `destination` is reached directly through the interface.
    pub fn route_add(socket: *Socket, name: []const u8, destination: Address) !void {
        var message: Message = .init(rtm_newroute, flag_create | flag_exclusive);
        const table_main = 254;
        const protocol_boot = 3;
        const scope_link = 253;
        const type_unicast = 1;
        const info = [12]u8{
            linux.AF.INET, 32,           0, 0, table_main, protocol_boot,
            scope_link,    type_unicast, 0, 0, 0,          0,
        };
        message.append_bytes(&info);
        message.attribute(rta_destination, &destination);
        var index_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &index_bytes, @intCast(try socket.index(name)), .little);
        message.attribute(rta_output_interface, &index_bytes);
        try socket.send(&message);
    }

    /// A blackhole route to `destination` (its packets dropped where they are sent: one direction
    /// of a partition between two hosts on the same link, a pod's), or with `present` false,
    /// that route removed.
    pub fn blackhole_set(socket: *Socket, destination: Address, present: bool) !void {
        var message: Message = if (present)
            .init(rtm_newroute, flag_create | flag_exclusive)
        else
            .init(rtm_delroute, 0);
        const table_main = 254;
        const protocol_boot = 3;
        const scope_universe = 0;
        const type_blackhole = 6;
        const info = [12]u8{
            linux.AF.INET,  32,             0, 0, table_main, protocol_boot,
            scope_universe, type_blackhole, 0, 0, 0,          0,
        };
        message.append_bytes(&info);
        message.attribute(rta_destination, &destination);
        try socket.send(&message);
    }

    /// The default route, through `gateway` on the interface (whose host route reaches it).
    pub fn route_default(socket: *Socket, name: []const u8, gateway: Address) !void {
        var message: Message = .init(rtm_newroute, flag_create | flag_exclusive);
        const table_main = 254;
        const protocol_boot = 3;
        const scope_universe = 0;
        const type_unicast = 1;
        const info = [12]u8{
            linux.AF.INET,  0,            0, 0, table_main, protocol_boot,
            scope_universe, type_unicast, 0, 0, 0,          0,
        };
        message.append_bytes(&info);
        message.attribute(rta_gateway, &gateway);
        var index_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &index_bytes, @intCast(try socket.index(name)), .little);
        message.attribute(rta_output_interface, &index_bytes);
        try socket.send(&message);
    }

    /// Delays and drops what leaves through the interface (one direction of a link), with
    /// netem's own randomness seeded by the caller so that it is a platform decision too.
    pub fn netem_set(socket: *Socket, name: []const u8, netem: Netem) !void {
        var message = netem_message(&try socket.tcmsg(name), netem);
        try socket.send(&message);
    }

    pub fn netem_clear(socket: *Socket, name: []const u8) !void {
        var message: Message = .init(rtm_delqdisc, 0);
        message.append_bytes(&try socket.tcmsg(name));
        socket.send(&message) catch |err| switch (err) {
            error.NetlinkRequestFailed => {}, // No qdisc to remove.
            else => return err,
        };
    }

    fn tcmsg(socket: *const Socket, name: []const u8) ![tcmsg_size]u8 {
        var header: [tcmsg_size]u8 = @splat(0);
        header[0] = linux.AF.UNSPEC;
        std.mem.writeInt(i32, header[4..8], try socket.index(name), .little);
        std.mem.writeInt(u32, header[8..12], tc_handle_netem, .little);
        std.mem.writeInt(u32, header[12..16], tc_handle_root, .little);
        return header;
    }

    fn index(socket: *const Socket, name: []const u8) !i32 {
        assert(name.len > 0);
        if (name.len > interface_name_size_max) return error.InterfaceNameTooLong;
        var request: extern struct { name: [16]u8, index: i32, padding: [20]u8 } = .{
            .name = @splat(0),
            .index = 0,
            .padding = @splat(0),
        };
        @memcpy(request.name[0..name.len], name);
        const result = linux.ioctl(socket.fd, siocgifindex, @intFromPtr(&request));
        if (linux.errno(result) != .SUCCESS) return error.NoSuchInterface;
        assert(request.index > 0);
        return request.index;
    }

    /// The netem on the interface as the kernel has it (null: none), read back so a heal is
    /// checked against the kernel rather than against what was asked of it (netem_set sent
    /// some options only when nonzero, and a change kept the omitted ones: run 952).
    pub fn netem_get(socket: *Socket, name: []const u8) !?NetemRead {
        const wanted = try socket.index(name);
        var request: Message = .init(rtm_getqdisc, flag_dump);
        var header: [tcmsg_size]u8 = @splat(0);
        header[0] = linux.AF.UNSPEC;
        std.mem.writeInt(i32, header[4..8], wanted, .little);
        request.append_bytes(&header);
        socket.sequence += 1;
        request.finish(socket.sequence);
        var kernel = std.mem.zeroes(linux.sockaddr.nl);
        kernel.family = linux.AF.NETLINK;
        const kernel_address: *const linux.sockaddr = @ptrCast(&kernel);
        const bytes = request.buffer[0..request.size];
        const sent = linux.sendto(socket.fd, bytes.ptr, bytes.len, 0, kernel_address, @sizeOf(linux.sockaddr.nl));
        if (linux.errno(sent) != .SUCCESS) return error.NetlinkSend;
        var found: ?NetemRead = null;
        var reply: [dump_size_max]u8 align(4) = undefined;
        while (true) {
            const received = linux.recvfrom(socket.fd, &reply, reply.len, 0, null, null);
            if (linux.errno(received) != .SUCCESS) return error.NetlinkReceive;
            var offset: usize = 0;
            while (offset + header_size <= received) {
                const length = std.mem.readInt(u32, reply[offset..][0..4], .little);
                if (length < header_size or offset + length > received) return error.NetlinkShortReply;
                const kind = std.mem.readInt(u16, reply[offset + 4 ..][0..2], .little);
                if (kind == message_done) return found;
                if (kind == message_error) return error.NetlinkRequestFailed;
                if (kind == rtm_newqdisc) {
                    if (netem_parse(reply[offset..][0..length], wanted)) |read| found = read;
                }
                offset += std.mem.alignForward(usize, length, 4);
            }
        }
    }

    fn send(socket: *Socket, message: *Message) !void {
        socket.sequence += 1;
        message.finish(socket.sequence);
        var kernel = std.mem.zeroes(linux.sockaddr.nl);
        kernel.family = linux.AF.NETLINK;
        const bytes = message.buffer[0..message.size];
        const kernel_address: *const linux.sockaddr = @ptrCast(&kernel);
        const kernel_size = @sizeOf(linux.sockaddr.nl);
        const sent = linux.sendto(socket.fd, bytes.ptr, bytes.len, 0, kernel_address, kernel_size);
        if (linux.errno(sent) != .SUCCESS) return error.NetlinkSend;
        assert(sent == bytes.len);
        return socket.acknowledgement();
    }

    fn acknowledgement(socket: *Socket) !void {
        var reply: [message_size_max]u8 align(4) = undefined;
        const received = linux.recvfrom(socket.fd, &reply, reply.len, 0, null, null);
        if (linux.errno(received) != .SUCCESS) return error.NetlinkReceive;
        if (received < header_size + 4) return error.NetlinkShortReply;
        const kind = std.mem.readInt(u16, reply[4..6], .little);
        if (kind != message_error) return error.NetlinkUnexpectedReply;
        const code = std.mem.readInt(i32, reply[header_size..][0..4], .little);
        if (code == 0) return;
        const errno: linux.E = @fromBackingInt(@intCast(-code));
        if (errno == .EXIST) return error.Exists;
        // A namespace named by a pid whose process exited (a zombie has none left).
        if (errno == .SRCH) return error.NoSuchNamespace;
        std.debug.print("netlink request failed: {s}\n", .{@tagName(errno)});
        return error.NetlinkRequestFailed;
    }
};

pub const Netem = struct {
    pub const ppm = 1_000_000;

    delay_ns: u64,
    jitter_ns: u64 = 0,
    /// Packets dropped, in parts per million (a baseline drops a few in ten thousand).
    loss_ppm: u32 = 0,
    duplicate_percent: u8 = 0,
    corrupt_percent: u8 = 0,
    /// Packets sent at once instead of delayed (needs a delay to reorder against).
    reorder_percent: u8 = 0,
    /// Bandwidth limit (0: none).
    rate_bytes_per_second: u32 = 0,
    /// Losses in bursts, netem's Gilbert-Elliott model, in place of `loss_ppm` (0: none): each
    /// packet moves a good link to its lossy state with burst_enter_ppm, and back with
    /// burst_leave_ppm; every packet in the lossy state is lost. Bursts a retransmission meets
    /// again, where independent drops are each retried away.
    burst_enter_ppm: u32 = 0,
    burst_leave_ppm: u32 = 0,
    seed: u64,

    /// The share of packets it drops, in ppm: independent drops, or bursts' stationary share.
    pub fn loss_effective_ppm(netem: Netem) u32 {
        if (netem.burst_enter_ppm == 0) return netem.loss_ppm;
        const enter: u64 = netem.burst_enter_ppm;
        const leave: u64 = @max(netem.burst_leave_ppm, 1);
        return @intCast(enter * ppm / (enter + leave));
    }
};

/// netem's probabilities are fractions of 2^32 - 1.
fn probability(percent: u8) u32 {
    assert(percent <= 100);
    return probability_ppm(@as(u32, percent) * (Netem.ppm / 100));
}

fn probability_ppm(parts: u32) u32 {
    assert(parts <= Netem.ppm);
    const scaled = @as(u64, std.math.maxInt(u32)) * parts / Netem.ppm;
    return @intCast(scaled);
}

/// One end of a veth pair: its interface name, its MAC address, and a process in the network
/// namespace it goes to.
pub const VethEnd = struct {
    name: []const u8,
    mac: [6]u8,
    pid: linux.pid_t,

    fn append(end: VethEnd, message: *Message) void {
        assert(end.name.len > 0 and end.name.len <= interface_name_size_max);
        assert(end.pid > 0);
        var name: [interface_name_size_max + 1]u8 = @splat(0);
        @memcpy(name[0..end.name.len], end.name);
        message.attribute(ifla_ifname, name[0 .. end.name.len + 1]);
        message.attribute(ifla_address, &end.mac);
        var pid_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &pid_bytes, @intCast(end.pid), .little);
        message.attribute(ifla_net_ns_pid, &pid_bytes);
    }
};

/// The message setting a link's netem (netem_set), apart for tests: `tcmsg` names the interface.
fn netem_message(tcmsg: *const [tcmsg_size]u8, netem: Netem) Message {
    assert(netem.loss_ppm <= Netem.ppm);
    var message: Message = .init(rtm_newqdisc, flag_create | flag_replace);
    message.append_bytes(tcmsg);
    message.attribute(tca_kind, "netem\x00");
    const options = message.nest_begin(tca_options);
    // struct tc_netem_qopt: latency, limit, loss, gap, duplicate, jitter (latency and jitter
    // in the legacy unit are superseded by the 64-bit nanosecond attributes below).
    var qopt: [24]u8 = @splat(0);
    std.mem.writeInt(u32, qopt[4..8], netem_limit_packets, .little);
    std.mem.writeInt(u32, qopt[8..12], probability_ppm(netem.loss_ppm), .little);
    std.mem.writeInt(u32, qopt[16..20], probability(netem.duplicate_percent), .little);
    message.append_bytes(&qopt);
    // struct tc_netem_reorder and tc_netem_corrupt: probability, correlation. Sent even when
    // zero, and the rate too: on a netem already there the kernel changes only what the
    // message has, so a link healed to its baseline kept an earlier fault's corruption,
    // reordering and rate (hunt run 952, timeline 300: a connection stuck on bad checksums
    // after faults stopped).
    var pair: [8]u8 = @splat(0);
    std.mem.writeInt(u32, pair[0..4], probability(netem.reorder_percent), .little);
    message.attribute(tca_netem_reorder, &pair);
    std.mem.writeInt(u32, pair[0..4], probability(netem.corrupt_percent), .little);
    message.attribute(tca_netem_corrupt, &pair);
    // struct tc_netem_rate: rate, packet overhead, cell size, cell overhead (0: no limit).
    var rate: [16]u8 = @splat(0);
    std.mem.writeInt(u32, rate[0..4], netem.rate_bytes_per_second, .little);
    message.attribute(tca_netem_rate, &rate);
    // Without it a change returns the link to independent drops (netem_change): a burst fault
    // healed to the baseline leaves none behind.
    if (netem.burst_enter_ppm > 0) {
        assert(netem.burst_enter_ppm <= Netem.ppm and netem.burst_leave_ppm <= Netem.ppm);
        const loss = message.nest_begin(tca_netem_loss);
        var model: [16]u8 = @splat(0); // p, r, h (sent in the lossy state: none), k1 (lost when good: none).
        std.mem.writeInt(u32, model[0..4], probability_ppm(netem.burst_enter_ppm), .little);
        std.mem.writeInt(u32, model[4..8], probability_ppm(netem.burst_leave_ppm), .little);
        message.attribute(netem_loss_ge, &model);
        message.nest_end(loss);
    }
    var value: [8]u8 = undefined;
    std.mem.writeInt(u64, &value, netem.delay_ns, .little);
    message.attribute(tca_netem_latency64, &value);
    std.mem.writeInt(u64, &value, netem.jitter_ns, .little);
    message.attribute(tca_netem_jitter64, &value);
    std.mem.writeInt(u64, &value, netem.seed, .little);
    message.attribute(tca_netem_prng_seed, &value);
    message.nest_end(options);
    return message;
}

/// A netem as the kernel reports it: probabilities in the kernel's unit (of 2^32 - 1), the rate
/// in bytes a second.
pub const NetemRead = struct {
    loss: u32 = 0,
    duplicate: u32 = 0,
    corrupt: u32 = 0,
    reorder: u32 = 0,
    rate_bytes_per_second: u32 = 0,
    /// Gilbert-Elliott's p (entering the lossy state), 0 for independent drops.
    burst: u32 = 0,

    /// Whether this netem does more than `expected` would (null: no netem): more loss,
    /// duplication, corruption or reordering, bursts, or a rate where none or a higher one is
    /// meant.
    pub fn harsher(read: NetemRead, expected: ?Netem) bool {
        const want: NetemRead = if (expected) |netem| .{
            .loss = probability_ppm(netem.loss_ppm),
            .duplicate = probability(netem.duplicate_percent),
            .corrupt = probability(netem.corrupt_percent),
            .reorder = probability(netem.reorder_percent),
            .rate_bytes_per_second = netem.rate_bytes_per_second,
            .burst = probability_ppm(netem.burst_enter_ppm),
        } else .{};
        const rate_harsher = read.rate_bytes_per_second != 0 and
            (want.rate_bytes_per_second == 0 or read.rate_bytes_per_second < want.rate_bytes_per_second);
        return read.loss > want.loss or read.duplicate > want.duplicate or
            read.corrupt > want.corrupt or read.reorder > want.reorder or rate_harsher or
            read.burst > want.burst;
    }
};

const dump_size_max = 32 * 1024;
const tc_netem_qopt_size = 24;

/// One RTM_NEWQDISC message of a dump: its netem's settings when it is a netem on interface
/// `wanted`.
fn netem_parse(message: []const u8, wanted: i32) ?NetemRead {
    if (message.len < header_size + tcmsg_size) return null;
    const interface = std.mem.readInt(i32, message[header_size + 4 ..][0..4], .little);
    if (interface != wanted) return null;
    var netem = false;
    var read: NetemRead = .{};
    var offset: usize = header_size + tcmsg_size;
    while (offset + 4 <= message.len) {
        const length = std.mem.readInt(u16, message[offset..][0..2], .little);
        const kind = std.mem.readInt(u16, message[offset + 2 ..][0..2], .little);
        if (length < 4 or offset + length > message.len) return null;
        const value = message[offset + 4 .. offset + length];
        if (kind == tca_kind) netem = std.mem.eql(u8, std.mem.sliceTo(value, 0), "netem");
        if (kind == tca_options and value.len >= tc_netem_qopt_size) {
            read.loss = std.mem.readInt(u32, value[8..12], .little);
            read.duplicate = std.mem.readInt(u32, value[16..20], .little);
            var inner: usize = tc_netem_qopt_size;
            while (inner + 4 <= value.len) {
                const inner_length = std.mem.readInt(u16, value[inner..][0..2], .little);
                const inner_kind = std.mem.readInt(u16, value[inner + 2 ..][0..2], .little);
                if (inner_length < 4 or inner + inner_length > value.len) break;
                const inner_value = value[inner + 4 .. inner + inner_length];
                if (inner_value.len >= 4) {
                    const first = std.mem.readInt(u32, inner_value[0..4], .little);
                    switch (inner_kind) {
                        tca_netem_corrupt => read.corrupt = first,
                        tca_netem_reorder => read.reorder = first,
                        tca_netem_rate => read.rate_bytes_per_second = first,
                        tca_netem_loss => if (inner_value.len >= 8) {
                            // Its nested model: Gilbert-Elliott's p, the first of its struct.
                            const model_kind = std.mem.readInt(u16, inner_value[2..4], .little);
                            if (model_kind == netem_loss_ge) read.burst = std.mem.readInt(u32, inner_value[4..8], .little);
                        },
                        else => {},
                    }
                }
                inner += std.mem.alignForward(usize, inner_length, 4);
            }
        }
        offset += std.mem.alignForward(usize, length, 4);
    }
    return if (netem) read else null;
}

const Message = struct {
    buffer: [message_size_max]u8 align(4) = undefined,
    size: u32 = header_size,

    fn init(kind: u16, flags: u16) Message {
        var message: Message = .{};
        @memset(message.buffer[0..header_size], 0);
        std.mem.writeInt(u16, message.buffer[4..6], kind, .little);
        std.mem.writeInt(u16, message.buffer[6..8], flag_request | flag_ack | flags, .little);
        return message;
    }

    fn append_bytes(message: *Message, bytes: []const u8) void {
        const padded = std.mem.alignForward(u32, @intCast(bytes.len), 4);
        assert(message.size + padded <= message_size_max);
        @memcpy(message.buffer[message.size..][0..bytes.len], bytes);
        @memset(message.buffer[message.size + bytes.len ..][0 .. padded - bytes.len], 0);
        message.size += padded;
    }

    fn attribute(message: *Message, kind: u16, value: []const u8) void {
        var header: [4]u8 = undefined;
        std.mem.writeInt(u16, header[0..2], @intCast(4 + value.len), .little);
        std.mem.writeInt(u16, header[2..4], kind, .little);
        assert(message.size % 4 == 0);
        message.append_bytes(&header);
        message.append_bytes(value);
    }

    /// Starts a nested attribute; returns its offset for `nest_end`.
    fn nest_begin(message: *Message, kind: u16) u32 {
        const offset = message.size;
        var header: [4]u8 = undefined;
        std.mem.writeInt(u16, header[0..2], 0, .little);
        std.mem.writeInt(u16, header[2..4], kind, .little);
        message.append_bytes(&header);
        return offset;
    }

    fn nest_end(message: *Message, offset: u32) void {
        assert(offset < message.size);
        const size: u16 = @intCast(message.size - offset);
        std.mem.writeInt(u16, message.buffer[offset..][0..2], size, .little);
    }

    fn finish(message: *Message, sequence: u32) void {
        assert(message.size >= header_size);
        std.mem.writeInt(u32, message.buffer[0..4], message.size, .little);
        std.mem.writeInt(u32, message.buffer[8..12], sequence, .little);
    }
};

/// Runs `operation` with the calling thread in the network namespace of process `pid`, then
/// returns to the namespace of process 1 (the guest's root namespace).
pub fn in_namespace_of(pid: linux.pid_t, operation: anytype, arguments: anytype) !void {
    assert(pid > 0);
    try namespace_enter(pid);
    defer namespace_enter(1) catch unreachable; // The root namespace always exists.
    var socket = try Socket.open();
    defer socket.close();
    return @call(.auto, operation, .{&socket} ++ arguments);
}

fn namespace_enter(pid: linux.pid_t) !void {
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/ns/net", .{pid}, 0) catch
        unreachable;
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return error.NoSuchNamespace;
    defer _ = linux.close(@intCast(fd));
    if (linux.errno(linux.setns(@intCast(fd), linux.CLONE.NEWNET)) != .SUCCESS) {
        return error.SetnsFailed;
    }
}

test "attributes are aligned and nests sized" {
    var message: Message = .init(rtm_newlink, 0);
    message.append_bytes(&@as([ifinfo_size]u8, @splat(0)));
    const nest = message.nest_begin(ifla_linkinfo);
    message.attribute(ifla_info_kind, "veth");
    message.nest_end(nest);
    message.finish(1);
    // The nest: its own header, then "veth" with its header (4 + 4).
    try std.testing.expectEqual(@as(u32, header_size + ifinfo_size + 4 + 8), message.size);
    const nest_size = std.mem.readInt(u16, message.buffer[nest..][0..2], .little);
    try std.testing.expectEqual(@as(u16, 4 + 8), nest_size);
}

/// The attribute `kind` among the netem options of a netem_message, if there.
fn netem_option(message: *const Message, kind: u16) ?[]const u8 {
    // After the header and the tcmsg: the kind attribute, then the options nest, its qopt
    // (24 bytes) first, then its attributes.
    var offset: u32 = header_size + tcmsg_size;
    while (offset < message.size) {
        const length = std.mem.readInt(u16, message.buffer[offset..][0..2], .little);
        const attribute_kind = std.mem.readInt(u16, message.buffer[offset + 2 ..][0..2], .little);
        if (attribute_kind == tca_options) {
            var inner: u32 = offset + 4 + 24;
            while (inner < offset + length) {
                const inner_length = std.mem.readInt(u16, message.buffer[inner..][0..2], .little);
                const inner_kind = std.mem.readInt(u16, message.buffer[inner + 2 ..][0..2], .little);
                if (inner_kind == kind) return message.buffer[inner + 4 .. inner + inner_length];
                inner += std.mem.alignForward(u32, inner_length, 4);
            }
            return null;
        }
        offset += std.mem.alignForward(u32, length, 4);
    }
    return null;
}

test "a netem without corruption, reordering or a rate says so: a change keeps what it omits" {
    // netem_change updates corrupt, reorder and rate only from attributes present, so a link
    // healed to its baseline kept an earlier fault's corruption (hunt run 952, timeline 300:
    // kclient's link to kine-2 corrupting 6% after faults stopped, a connection stuck on bad
    // checksums).
    const tcmsg: [tcmsg_size]u8 = @splat(0);
    const message = netem_message(&tcmsg, .{ .delay_ns = 1_000_000, .seed = 7 });
    inline for (.{ tca_netem_corrupt, tca_netem_reorder, tca_netem_rate }) |kind| {
        const value = netem_option(&message, kind) orelse return error.TestOptionMissing;
        try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, value[0..4], .little));
    }
    const corrupting = netem_message(&tcmsg, .{ .delay_ns = 0, .corrupt_percent = 6, .seed = 7 });
    const corrupt = netem_option(&corrupting, tca_netem_corrupt) orelse return error.TestOptionMissing;
    try std.testing.expectEqual(probability(6), std.mem.readInt(u32, corrupt[0..4], .little));
}

test "a qdisc of a dump reads back as the netem it carries, and only on its interface" {
    var tcmsg: [tcmsg_size]u8 = @splat(0);
    std.mem.writeInt(i32, tcmsg[4..8], 5, .little);
    // A netem the way the kernel reports one: the request's layout (qopt, then the options).
    var message = netem_message(&tcmsg, .{ .delay_ns = 0, .loss_ppm = 10_000, .corrupt_percent = 6, .reorder_percent = 14, .rate_bytes_per_second = 677_252, .seed = 1 });
    message.finish(1);
    const bytes = message.buffer[0..message.size];
    const read = netem_parse(bytes, 5) orelse return error.TestNotRead;
    try std.testing.expectEqual(probability(6), read.corrupt);
    try std.testing.expectEqual(probability(14), read.reorder);
    try std.testing.expectEqual(@as(u32, 677_252), read.rate_bytes_per_second);
    try std.testing.expectEqual(probability_ppm(10_000), read.loss);
    try std.testing.expect(netem_parse(bytes, 6) == null);
    // Against what the bookkeeping holds: the baseline is milder, the same netem is not.
    try std.testing.expect(read.harsher(.{ .delay_ns = 1_000_000, .loss_ppm = 1000, .seed = 2 }));
    try std.testing.expect(read.harsher(null));
    try std.testing.expect(!read.harsher(.{ .delay_ns = 0, .loss_ppm = 10_000, .corrupt_percent = 6, .reorder_percent = 14, .rate_bytes_per_second = 677_252, .seed = 1 }));
    const mild = NetemRead{ .loss = probability_ppm(500) };
    try std.testing.expect(!mild.harsher(.{ .delay_ns = 1_000_000, .loss_ppm = 1000, .seed = 2 }));
}

test "a netem with bursts carries Gilbert-Elliott's model, read back harsher than independent drops" {
    var tcmsg: [tcmsg_size]u8 = @splat(0);
    std.mem.writeInt(i32, tcmsg[4..8], 5, .little);
    const bursting: Netem = .{ .delay_ns = 0, .burst_enter_ppm = 20_000, .burst_leave_ppm = 200_000, .seed = 1 };
    var message = netem_message(&tcmsg, bursting);
    message.finish(1);
    const read = netem_parse(message.buffer[0..message.size], 5) orelse return error.TestNotRead;
    try std.testing.expectEqual(probability_ppm(20_000), read.burst);
    // Healed to a baseline of independent drops, a burst model left on is harsher; itself is not.
    try std.testing.expect(read.harsher(.{ .delay_ns = 1_000_000, .loss_ppm = 1000, .seed = 2 }));
    try std.testing.expect(!read.harsher(bursting));
    // A netem without it carries none: a change returns the link to independent drops.
    var plain = netem_message(&tcmsg, .{ .delay_ns = 0, .loss_ppm = 1000, .seed = 1 });
    plain.finish(1);
    const plain_read = netem_parse(plain.buffer[0..plain.size], 5) orelse return error.TestNotRead;
    try std.testing.expectEqual(@as(u32, 0), plain_read.burst);
    // A burst's stationary share of drops: p / (p + r).
    try std.testing.expectEqual(@as(u32, 90_909), bursting.loss_effective_ppm());
}
