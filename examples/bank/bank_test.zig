// SPDX-License-Identifier: MIT
//! Example test program: a bank kept in Redis, with a deliberate concurrency bug.
//!
//! Transfers read both balances with separate GETs and then write both in one MULTI/EXEC. The
//! writes are atomic, the reads are not checked (no WATCH), so two concurrent transfers touching
//! the same account can lose an update and money appears or disappears. Whether that happens
//! depends on where the guest scheduler preempts a transfer between its reads and its writes,
//! which is exactly what determinismo explores and then replays.
//!
//! The system: one Redis node from the official image. Profiles:
//!   default    Redis may be paused, isolated, or cut off from the tests
//!   restarts   also restarts, with an append-only file so the data survives them
//!   built      Redis built from examples/bank/redis/Dockerfile
//! Scenarios, both from the same function with a different account count:
//!   bank       10 accounts
//!   bank_hot   2 accounts: every transfer collides
//!   bank_cold  40 accounts: transfers seldom collide, so a timeline that loses money was
//!              decided at its colliding transfers (what causality analysis looks for)
//!   bank_steps 4 accounts, and each step said as an event of its own: `bank_read` (what a
//!              transfer read), `bank_commit` (what it wrote), `bank_reject`, `bank_audit`
//!              (the balances and their total), each with the driver's process as its
//!              `client`. A step at Redis and its event are under one lock, so the events
//!              are in the order Redis took the steps: without it a client that has its
//!              reply says so only when it runs again, after others' steps (a write's event
//!              after the event of a read that saw it). The bug is as it was: a transfer's
//!              read and its write are two steps. The trace a spec is checked against
//!              (`determinismo quint`, docs/QUINT.md; examples/bank/quint).
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sdk = @import("determinismo");
const Connection = @import("resp");

const Nodes = struct { redis: sdk.Node };
const System = sdk.System(Nodes);

const redis_image = "docker.io/library/redis:7.4-alpine";
const redis_port = 6379;
const balance_initial = 100;
const transfers_per_driver = 25;
const amount_max = 50;
/// The longest balance Redis can hold for us: an i64 in decimal, its sign included.
const balance_digits_max = 20;
const audit_attempts_max = 200;

comptime {
    assert(amount_max < balance_initial);
}

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{
        .describe = describe,
        .scenarios = .{
            .bank = Bank(10, false).scenario,
            .bank_hot = Bank(2, false).scenario,
            .bank_cold = Bank(40, false).scenario,
            .bank_drawn = Bank(10, false).scenario_drawn,
            .bank_steps = Bank(4, true).scenario,
        },
    });
}

fn describe(d: *System.Describe) !void {
    const default = try d.profile("default");
    default.node(.redis, .{
        .image = redis_image,
        .command = &.{ "redis-server", "--save", "", "--appendonly", "no" },
        .ready = .{ .tcp = redis_port },
    });
    // The default with Redis's ready line declared retroactive by the workload itself (the e2e
    // retroactive check: as `--retroactive`).
    const quiet = try d.profile("retroactive");
    quiet.node(.redis, .{
        .image = redis_image,
        .command = &.{ "redis-server", "--save", "", "--appendonly", "no" },
        .ready = .{ .tcp = redis_port },
    });
    quiet.retroactive = &.{"Ready to accept"};
    const restarts = try d.profile("restarts");
    restarts.node(.redis, .{
        .image = redis_image,
        .command = &.{
            "redis-server", "--save", "", "--appendonly", "yes", "--appendfsync", "always",
        },
        .ready = .{ .tcp = redis_port },
        .faults = .{ .restart = true },
    });
    // The same Redis, built from a Dockerfile (paths are relative to where determinismo runs).
    const built = try d.profile("built");
    built.node(.redis, .{
        .build = .{ .context = "examples/bank/redis" },
        .ready = .{ .tcp = redis_port },
    });
}

/// Everything about a bank of `account_count` accounts: its scenario and its commands. `steps`:
/// each step said as an event (the scenario bank_steps).
fn Bank(comptime account_count: u32, comptime steps: bool) type {
    comptime assert(account_count >= 2);
    comptime assert(account_count <= Connection.array_count_max);
    return struct {
        const balance_total = account_count * balance_initial;

        fn scenario(s: *System.Scenario) void {
            s.setup("accounts", accounts);
            s.parallel_driver("transfer", transfer_many);
            s.anytime("audit_live", audit_anytime);
            s.finally("audit_final", audit_finally);
        }

        /// The same, its driver phase's length drawn (up to 20 s) instead of its starts (the
        /// e2e `drive` check).
        fn scenario_drawn(s: *System.Scenario) void {
            scenario(s);
            s.drive_ms_max = 20_000;
        }

        fn accounts(context: *System.Context) !void {
            var connection: Connection = undefined;
            try connection.open(context.nodes.redis.address, redis_port);
            defer connection.close();
            for (0..account_count) |account| {
                var key_buffer: [16]u8 = undefined;
                _ = try connection.call(&.{ "SET", account_key(&key_buffer, account), "100" });
            }
        }

        fn transfer_many(context: *System.Context) !void {
            var connection: Connection = undefined;
            connection.open(context.nodes.redis.address, redis_port) catch |err| {
                return unavailable(err);
            };
            defer connection.close();
            for (0..transfers_per_driver) |_| {
                transfer(&connection) catch |err| return unavailable(err);
            }
        }

        fn transfer(connection: *Connection) !void {
            const source = sdk.random_below(account_count);
            const target = (source + 1 + sdk.random_below(account_count - 1)) % account_count;
            assert(source != target);
            const amount: i64 = @intCast(1 + sdk.random_below(amount_max));

            var source_key_buffer: [16]u8 = undefined;
            var target_key_buffer: [16]u8 = undefined;
            const source_key = account_key(&source_key_buffer, source);
            const target_key = account_key(&target_key_buffer, target);
            // The bug: these reads are not protected by WATCH, so they can be stale by the EXEC.
            const client = if (steps) linux.getpid() else 0;
            var source_balance: i64 = undefined;
            var target_balance: i64 = undefined;
            {
                const step = step_begin();
                defer step_end(step);
                source_balance = try read_balance(connection, source_key);
                target_balance = try read_balance(connection, target_key);
                if (steps) sdk.event("bank_read", .{
                    .client = client,
                    .source = source,
                    .target = target,
                    .source_balance = source_balance,
                    .target_balance = target_balance,
                });
            }
            if (source_balance < amount) {
                const details = .{ .amount = amount };
                sdk.sometimes(true, "transfer rejected for insufficient funds", details);
                if (steps) sdk.event("bank_reject", .{ .client = client, .amount = amount });
                return;
            }
            var source_value_buffer: [24]u8 = undefined;
            var target_value_buffer: [24]u8 = undefined;
            const source_value = try print_balance(&source_value_buffer, source_balance - amount);
            const target_value = try print_balance(&target_value_buffer, target_balance + amount);
            {
                const step = step_begin();
                defer step_end(step);
                _ = try connection.call(&.{"MULTI"});
                _ = try connection.call(&.{ "SET", source_key, source_value });
                _ = try connection.call(&.{ "SET", target_key, target_value });
                var exec_replies: [2]?[]const u8 = undefined;
                const exec_count = try connection.call_array(&.{"EXEC"}, &exec_replies, &.{});
                assert(exec_count == 2); // Both SETs ran: nothing was WATCHed, so EXEC never aborts.
                if (steps) sdk.event("bank_commit", .{
                    .client = client,
                    .amount = amount,
                    .source_balance = source_balance - amount,
                    .target_balance = target_balance + amount,
                });
            }
            sdk.reachable("transfer committed", .{ .amount = amount });
        }

        fn audit_anytime(context: *System.Context) !void {
            audit(context, "anytime") catch |err| return unavailable(err);
        }

        /// Faults are over by now: Redis must answer again, soon.
        fn audit_finally(context: *System.Context) !void {
            sdk.retry(audit_attempts_max, 50, audit, .{ context, "finally" }) catch |err| {
                if (!Connection.is_unavailable(err)) return err;
                sdk.assert_unreachable("redis answers once faults stop", .{});
                return error.RedisUnavailable;
            };
        }

        fn audit(context: *System.Context, phase: []const u8) !void {
            var connection: Connection = undefined;
            try connection.open(context.nodes.redis.address, redis_port);
            defer connection.close();
            var keys_buffer: [account_count][16]u8 = undefined;
            var command: [account_count + 1][]const u8 = undefined;
            command[0] = "MGET";
            for (0..account_count) |account| {
                command[account + 1] = account_key(&keys_buffer[account], account);
            }
            var values: [account_count]?[]const u8 = undefined;
            var storage: [account_count * balance_digits_max]u8 = undefined;
            const audit_step = step_begin();
            defer step_end(audit_step);
            const count = try connection.call_array(&command, &values, &storage);
            assert(count == account_count);
            var total: i64 = 0;
            if (steps) {
                var balances: [account_count]i64 = undefined;
                for (values, &balances) |value, *balance| {
                    balance.* = try std.fmt.parseInt(i64, value orelse return error.MissingAccount, 10);
                    total += balance.*;
                }
                sdk.event("bank_audit", .{ .balances = balances, .total = total });
            } else {
                for (values) |value| {
                    const balance = value orelse return error.MissingAccount;
                    total += try std.fmt.parseInt(i64, balance, 10);
                }
            }
            const details = .{ .total = total, .phase = phase, .accounts = account_count };
            sdk.always(total == balance_total, "total balance is conserved", details);
            if (std.mem.eql(u8, phase, "anytime")) sdk.sometimes(true, "anytime audit ran", .{});
            if (std.mem.eql(u8, phase, "finally")) sdk.sometimes(true, "finally audit ran", .{});
        }

        /// bank_steps: a step at Redis and its event under one lock (a file's, across the
        /// drivers' processes), taken here and given back by step_end.
        fn step_begin() linux.fd_t {
            if (!steps) return -1;
            const opened = linux.open("/run/bank-steps.lock", .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o600);
            assert(linux.errno(opened) == .SUCCESS);
            const fd: linux.fd_t = @intCast(opened);
            while (linux.errno(linux.flock(fd, std.posix.LOCK.EX)) == .INTR) {}
            return fd;
        }

        fn step_end(fd: linux.fd_t) void {
            if (!steps) return;
            _ = linux.close(fd); // Its lock goes with it.
        }

        fn account_key(buffer: *[16]u8, account: u64) []const u8 {
            assert(account < account_count);
            return std.fmt.bufPrint(buffer, "account:{d}", .{account}) catch unreachable;
        }
    };
}

/// Faults make Redis unreachable for a while: a driver that meets that gives up, and we note it.
fn unavailable(err: anyerror) !void {
    if (!Connection.is_unavailable(err)) return err;
    sdk.sometimes(true, "redis was unavailable to a test command", .{ .err = @errorName(err) });
}

fn read_balance(connection: *Connection, key: []const u8) !i64 {
    const reply = try connection.call(&.{ "GET", key });
    if (reply != .bulk) return error.BadReply;
    return std.fmt.parseInt(i64, reply.bulk orelse return error.MissingAccount, 10);
}

fn print_balance(buffer: *[24]u8, balance: i64) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{d}", .{balance});
}
