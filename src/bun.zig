/// The functions in this file are used throughout Bun's codebase
//
// Do not import this file directly!
//   To import it:
//      @import("root").bun
//
// Otherwise, you risk a circular dependency or Zig including multiple copies of this file which leads to strange bugs.
const builtin = @import("builtin");
const std = @import("std");
const bun = @This();

pub const Environment = @import("env.zig");

pub const use_mimalloc = true;

pub const default_allocator: std.mem.Allocator = if (!use_mimalloc)
    std.heap.c_allocator
else
    @import("./allocators/memory_allocator.zig").c_allocator;

/// Zeroing memory allocator
pub const z_allocator: std.mem.Allocator = if (!use_mimalloc)
    std.heap.c_allocator
else
    @import("./allocators/memory_allocator.zig").z_allocator;

pub const callmod_inline: std.builtin.CallModifier = if (builtin.mode == .Debug) .auto else .always_inline;
pub const callconv_inline: std.builtin.CallingConvention = if (builtin.mode == .Debug) .Unspecified else .Inline;

pub extern "c" fn powf(x: f32, y: f32) f32;
pub extern "c" fn pow(x: f64, y: f64) f64;

/// Restrict a value to a certain interval unless it is a float and NaN.
pub inline fn clamp(self: anytype, min: @TypeOf(self), max: @TypeOf(self)) @TypeOf(self) {
    bun.debugAssert(min <= max);
    if (comptime (@TypeOf(self) == f32 or @TypeOf(self) == f64)) {
        return clampFloat(self, min, max);
    }
    return std.math.clamp(self, min, max);
}

/// Restrict a value to a certain interval unless it is NaN.
///
/// Returns `max` if `self` is greater than `max`, and `min` if `self` is
/// less than `min`. Otherwise this returns `self`.
///
/// Note that this function returns NaN if the initial value was NaN as
/// well.
pub inline fn clampFloat(_self: anytype, min: @TypeOf(_self), max: @TypeOf(_self)) @TypeOf(_self) {
    if (comptime !(@TypeOf(_self) == f32 or @TypeOf(_self) == f64)) {
        @compileError("Only call this on floats.");
    }
    var self = _self;
    if (self < min) {
        self = min;
    }
    if (self > max) {
        self = max;
    }
    return self;
}

/// We cannot use a threadlocal memory allocator for FileSystem-related things
/// FileSystem is a singleton.
pub const fs_allocator = default_allocator;

pub fn typedAllocator(comptime T: type) std.mem.Allocator {
    if (heap_breakdown.enabled)
        return heap_breakdown.allocator(comptime T);

    return default_allocator;
}

pub inline fn namedAllocator(comptime name: [:0]const u8) std.mem.Allocator {
    if (heap_breakdown.enabled)
        return heap_breakdown.namedAllocator(name);

    return default_allocator;
}

pub const OOM = std.mem.Allocator.Error;

pub const JSError = error{
    /// There is an active exception on the global object.
    /// You should almost never have to construct this manually.
    JSError,
    // XXX: This is temporary! meghan will remove this soon
    OutOfMemory,
};

pub const JSOOM = OOM || JSError;

pub const detectCI = @import("./ci_info.zig").detectCI;

/// Adding to this namespace is considered deprecated.
///
/// If the declaration truly came from C, it should be perfectly possible to
/// translate the definition and put it in `c-headers-for-zig.h`, and available
/// via the lowercase `c` namespace. Wrappers around functions should go in a
/// more specific namespace, such as `bun.spawn`, `bun.strings` or `bun.sys`
///
/// By avoiding manual transcription of C headers into Zig, we avoid bugs due to
/// different definitions between platforms, as well as very common mistakes
/// that can be made when porting definitions. It also keeps code much cleaner.
pub const C = @import("c.zig");
/// Translated from `c-headers-for-zig.h` for the current platform.
pub const c = @import("translated-c-headers");

pub const sha = @import("./sha.zig");
pub const FeatureFlags = @import("feature_flags.zig");
pub const meta = @import("./meta.zig");
pub const base64 = @import("./base64/base64.zig");
pub const path = @import("./resolver/resolve_path.zig");
pub const resolver = @import("./resolver/resolver.zig");
pub const DirIterator = @import("./bun.js/node/dir_iterator.zig");
pub const PackageJSON = @import("./resolver/package_json.zig").PackageJSON;
pub const fmt = @import("./fmt.zig");
pub const allocators = @import("./allocators.zig");
pub const bun_js = @import("./bun_js.zig");

/// All functions and interfaces provided from Bun's `bindgen` utility.
pub const gen = @import("bun.js/bindings/GeneratedBindings.zig");
comptime {
    _ = &gen; // reference bindings
}

/// Copied from Zig std.trait
pub const trait = @import("./trait.zig");
/// Copied from Zig std.Progress before 0.13 rewrite
pub const Progress = @import("./Progress.zig");
/// Modified version of Zig's ComptimeStringMap
pub const comptime_string_map = @import("./comptime_string_map.zig");
pub const ComptimeStringMap = comptime_string_map.ComptimeStringMap;
pub const ComptimeStringMap16 = comptime_string_map.ComptimeStringMap16;
pub const ComptimeStringMapWithKeyType = comptime_string_map.ComptimeStringMapWithKeyType;

pub const glob = @import("./glob.zig");
pub const patch = @import("./patch.zig");
pub const ini = @import("./ini.zig");
pub const Bitflags = @import("./bitflags.zig").Bitflags;
pub const css = @import("./css/css_parser.zig");
pub const csrf = @import("./csrf.zig");
pub const validators = @import("./bun.js/node/util/validators.zig");

pub const shell = @import("./shell/shell.zig");

pub const Output = @import("./output.zig");
pub const Global = @import("./Global.zig");

// make this non-pub after https://github.com/ziglang/zig/issues/18462 is resolved
pub const FileDescriptorInt = if (Environment.isBrowser)
    u0
else if (Environment.isWindows)
    // On windows, this is a bitcast "bun.FDImpl" struct
    // Do not bitcast it to *anyopaque manually, but instead use `fdcast()`
    u64
else
    std.posix.fd_t;

pub const FD = FileDescriptor;
pub const FileDescriptor = enum(FileDescriptorInt) {
    /// Zero is used in old filesystem code to indicate "no file descriptor"
    /// This is problematic because on POSIX, this is ambiguous with stdin being 0.
    /// All code that uses this should migrate to invalid_fd to represent invalid states.
    zero = 0,
    // Represents an invalid file descriptor. This is used instead of null to
    // avoid an extra bit.
    // invalid = @intFromEnum(invalid_fd),
    _,

    /// Do not use this function in new code.
    ///
    /// Interpreting a FD as an integer is almost certainly a mistake.
    /// On Windows, it is always a mistake, as the integer is bitcast of a tagged packed struct.
    ///
    /// TODO(@paperclover): remove this API.
    pub fn int(self: FileDescriptor) std.posix.fd_t {
        if (Environment.isWindows)
            @compileError("FileDescriptor.int() is not allowed on Windows.");
        return @intFromEnum(self);
    }

    pub fn writeTo(fd: FileDescriptor, writer: anytype, endian: std.builtin.Endian) !void {
        try writer.writeInt(FileDescriptorInt, @intFromEnum(fd), endian);
    }

    pub fn readFrom(reader: anytype, endian: std.builtin.Endian) !FileDescriptor {
        return @enumFromInt(try reader.readInt(FileDescriptorInt, endian));
    }

    /// converts a `bun.FileDescriptor` into the native operating system fd
    ///
    /// On non-windows this does nothing, but on windows it converts UV descriptors
    /// to Windows' *HANDLE, and casts the types for proper usage.
    ///
    /// This may be needed in places where a FileDescriptor is given to `std` or `kernel32` apis
    pub fn cast(fd: FileDescriptor) std.posix.fd_t {
        if (!Environment.isWindows) return fd.int();
        // if not having this check, the cast may crash zig compiler?
        if (@inComptime() and fd == invalid_fd) return FDImpl.invalid.system();
        return fd.impl().system();
    }

    pub fn asDir(fd: FileDescriptor) std.fs.Dir {
        return std.fs.Dir{ .fd = fd.cast() };
    }

    pub fn asFile(fd: FileDescriptor) std.fs.File {
        return std.fs.File{ .handle = fd.cast() };
    }

    pub fn format(fd: FileDescriptor, comptime fmt_: string, options_: std.fmt.FormatOptions, writer: anytype) !void {
        try FDImpl.format(fd.impl(), fmt_, options_, writer);
    }

    pub fn assertValid(fd: FileDescriptor) void {
        fd.impl().assertValid();
    }

    pub fn isValid(fd: FileDescriptor) bool {
        return fd.impl().isValid();
    }

    pub fn assertKind(fd: FileDescriptor, kind: FDImpl.Kind) void {
        assert(fd.impl().kind == kind);
    }

    pub fn cwd() FileDescriptor {
        return toFD(std.fs.cwd().fd);
    }

    pub fn eq(this: FileDescriptor, that: FileDescriptor) bool {
        if (Environment.isPosix) return this.int() == that.int();

        const this_ = FDImpl.decode(this);
        const that_ = FDImpl.decode(that);
        return switch (this_.kind) {
            .system => switch (that_.kind) {
                .system => this_.value.as_system == that_.value.as_system,
                .uv => false,
            },
            .uv => switch (that_.kind) {
                .system => false,
                .uv => this_.value.as_uv == that_.value.as_uv,
            },
        };
    }

    pub fn isStdio(fd: FileDescriptor) bool {
        // fd.assertValid();
        const decoded = fd.impl();
        return switch (Environment.os) {
            else => decoded.value.as_system < 3,
            .windows => switch (decoded.kind) {
                .system => fd == win32.STDIN_FD or
                    fd == win32.STDOUT_FD or
                    fd == win32.STDERR_FD,
                .uv => decoded.value.as_uv < 3,
            },
        };
    }

    pub fn toJS(value: FileDescriptor, global: *JSC.JSGlobalObject) JSC.JSValue {
        return FDImpl.decode(value).toJS(global);
    }

    pub fn impl(fd: FileDescriptor) FDImpl {
        return FDImpl.decode(fd);
    }
};

pub const FDImpl = @import("./fd.zig").FDImpl;

// When we are on a computer with an absurdly high number of max open file handles
// such is often the case with macOS
// As a useful optimization, we can store file descriptors and just keep them open...forever
pub const StoredFileDescriptorType = FileDescriptor;

/// Thin wrapper around iovec / libuv buffer
/// This is used for readv/writev calls.
pub const PlatformIOVec = if (Environment.isWindows)
    windows.libuv.uv_buf_t
else
    std.posix.iovec;

pub const PlatformIOVecConst = if (Environment.isWindows)
    windows.libuv.uv_buf_t
else
    std.posix.iovec_const;

pub fn platformIOVecCreate(input: []const u8) PlatformIOVec {
    if (Environment.allow_assert) {
        if (input.len > @as(usize, std.math.maxInt(u32))) {
            Output.debugWarn("call to bun.PlatformIOVec.init with length larger than u32, this will overflow on windows", .{});
        }
    }
    // TODO: remove this constCast by making the input mutable
    return .{ .len = @intCast(input.len), .base = @constCast(input.ptr) };
}

pub fn platformIOVecConstCreate(input: []const u8) PlatformIOVecConst {
    if (Environment.allow_assert) {
        if (input.len > @as(usize, std.math.maxInt(u32))) {
            Output.debugWarn("call to bun.PlatformIOVecConst.init with length larger than u32, this will overflow on windows", .{});
        }
    }
    // TODO: remove this constCast by adding uv_buf_t_const
    return .{ .len = @intCast(input.len), .base = @constCast(input.ptr) };
}

pub fn platformIOVecToSlice(iovec: PlatformIOVec) []u8 {
    if (Environment.isWindows) return windows.libuv.uv_buf_t.slice(iovec);
    return iovec.base[0..iovec.len];
}

pub const libarchive = @import("./libarchive/libarchive.zig");

pub const StringTypes = @import("string_types.zig");
pub const stringZ = StringTypes.stringZ;
pub const string = StringTypes.string;
pub const CodePoint = StringTypes.CodePoint;

pub const MAX_PATH_BYTES: usize = if (Environment.isWasm) 1024 else std.fs.max_path_bytes;
pub const PathBuffer = [MAX_PATH_BYTES]u8;
pub const WPathBuffer = [std.os.windows.PATH_MAX_WIDE]u16;
pub const OSPathChar = if (Environment.isWindows) u16 else u8;
pub const OSPathSliceZ = [:0]const OSPathChar;
pub const OSPathSlice = []const OSPathChar;
pub const OSPathBuffer = if (Environment.isWindows) WPathBuffer else PathBuffer;

pub inline fn cast(comptime To: type, value: anytype) To {
    if (@typeInfo(@TypeOf(value)) == .int) {
        return @ptrFromInt(@as(usize, value));
    }

    return @ptrCast(@alignCast(value));
}

pub fn len(value: anytype) usize {
    return switch (@typeInfo(@TypeOf(value))) {
        .array => |info| info.len,
        .vector => |info| info.len,
        .pointer => |info| switch (info.size) {
            .one => switch (@typeInfo(info.child)) {
                .array => |array| brk: {
                    if (array.sentinel_ptr != null) {
                        @compileError("use bun.sliceTo");
                    }

                    break :brk array.len;
                },
                else => @compileError("invalid type given to std.mem.len"),
            },
            .many => {
                const sentinel_ptr = info.sentinel_ptr orelse
                    @compileError("length of pointer with no sentinel");
                const sentinel = @as(*align(1) const info.child, @ptrCast(sentinel_ptr)).*;

                return std.mem.indexOfSentinel(info.child, sentinel, value);
            },
            .c => {
                assert(value != null);
                return std.mem.indexOfSentinel(info.child, 0, value);
            },
            .slice => value.len,
        },
        .@"struct" => |info| if (info.is_tuple) {
            return info.fields.len;
        } else @compileError("invalid type given to std.mem.len"),
        else => @compileError("invalid type given to std.mem.len"),
    };
}

fn Span(comptime T: type) type {
    switch (@typeInfo(T)) {
        .optional => |optional_info| {
            return ?Span(optional_info.child);
        },
        .pointer => |ptr_info| {
            var new_ptr_info = ptr_info;
            switch (ptr_info.size) {
                .one => switch (@typeInfo(ptr_info.child)) {
                    .array => |info| {
                        new_ptr_info.child = info.child;
                        new_ptr_info.sentinel_ptr = info.sentinel_ptr;
                    },
                    else => @compileError("invalid type given to std.mem.Span"),
                },
                .c => {
                    new_ptr_info.sentinel_ptr = &@as(ptr_info.child, 0);
                    new_ptr_info.is_allowzero = false;
                },
                .many, .slice => {},
            }
            new_ptr_info.size = .slice;
            return @Type(.{ .pointer = new_ptr_info });
        },
        else => @compileError("invalid type given to std.mem.Span: " ++ @typeName(T)),
    }
}

pub fn span(pointer: anytype) Span(@TypeOf(pointer)) {
    if (@typeInfo(@TypeOf(pointer)) == .optional) {
        if (pointer) |non_null| {
            return span(non_null);
        } else {
            return null;
        }
    }
    const Result = Span(@TypeOf(pointer));
    const l = len(pointer);
    const ptr_info = @typeInfo(Result).pointer;
    if (ptr_info.sentinel_ptr) |s_ptr| {
        const s = @as(*align(1) const ptr_info.child, @ptrCast(s_ptr)).*;
        return pointer[0..l :s];
    } else {
        return pointer[0..l];
    }
}

pub const IdentityContext = @import("./identity_context.zig").IdentityContext;
pub const ArrayIdentityContext = @import("./identity_context.zig").ArrayIdentityContext;
pub const StringHashMapUnowned = struct {
    pub const Key = struct {
        hash: u64,
        len: usize,

        pub fn init(str: []const u8) Key {
            return Key{
                .hash = hash(str),
                .len = str.len,
            };
        }
    };

    pub const Adapter = struct {
        pub fn eql(_: @This(), a: Key, b: Key) bool {
            return a.hash == b.hash and a.len == b.len;
        }

        pub fn hash(_: @This(), key: Key) u64 {
            return key.hash;
        }
    };
};
pub const OffsetList = @import("./baby_list.zig").OffsetList;
pub const BabyList = @import("./baby_list.zig").BabyList;
pub const ByteList = BabyList(u8);
pub const OffsetByteList = OffsetList(u8);

pub fn DebugOnly(comptime Type: type) type {
    if (comptime Environment.isDebug) {
        return Type;
    }

    return void;
}

pub fn DebugOnlyDefault(comptime val: anytype) if (Environment.isDebug) @TypeOf(val) else void {
    if (comptime Environment.isDebug) {
        return val;
    }

    return {};
}

pub inline fn range(comptime min: anytype, comptime max: anytype) [max - min]usize {
    return comptime brk: {
        var slice: [max - min]usize = undefined;
        for (min..max) |i| {
            slice[i - min] = i;
        }
        break :brk slice;
    };
}

pub fn copy(comptime Type: type, dest: []Type, src: []const Type) void {
    const input: []const u8 = std.mem.sliceAsBytes(src);
    const output: []u8 = std.mem.sliceAsBytes(dest);

    return memmove(output, input);
}

pub fn clone(item: anytype, allocator: std.mem.Allocator) !@TypeOf(item) {
    const T = @TypeOf(item);

    if (std.meta.hasFn(T, "clone")) {
        return try item.clone(allocator);
    }

    const Child = std.meta.Child(T);
    if (comptime trait.isContainer(Child)) {
        if (std.meta.hasFn(Child, "clone")) {
            const slice = try allocator.alloc(Child, item.len);
            for (slice, 0..) |*val, i| {
                val.* = try item[i].clone(allocator);
            }
            return slice;
        }

        @compileError("Expected clone() to exist for slice child: " ++ @typeName(Child));
    }

    return try allocator.dupe(Child, item);
}

pub const StringBuilder = @import("./string.zig").StringBuilder;

pub const LinearFifo = @import("./linear_fifo.zig").LinearFifo;
pub const linux = struct {
    pub const memfd_allocator = @import("./allocators/linux_memfd_allocator.zig").LinuxMemFdAllocator;
};

/// hash a string
pub fn hash(content: []const u8) u64 {
    return std.hash.Wyhash.hash(0, content);
}

/// Get a random-ish value
pub fn fastRandom() u64 {
    const pcrng = struct {
        const random_seed = struct {
            var seed_value: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
            pub fn get() u64 {
                // This is slightly racy but its fine because this memoization is done as a performance optimization
                // and we only need to do it once per process
                var value = seed_value.load(.monotonic);
                while (value == 0) : (value = seed_value.load(.monotonic)) {
                    if (comptime Environment.isDebug or Environment.is_canary) outer: {
                        if (getenvZ("BUN_DEBUG_HASH_RANDOM_SEED")) |env| {
                            value = std.fmt.parseInt(u64, env, 10) catch break :outer;
                            seed_value.store(value, .monotonic);
                            return value;
                        }
                    }
                    csprng(std.mem.asBytes(&value));
                    seed_value.store(value, .monotonic);
                }

                return value;
            }
        };

        var prng_: ?std.Random.DefaultPrng = null;

        pub fn get() u64 {
            if (prng_ == null) {
                prng_ = std.Random.DefaultPrng.init(random_seed.get());
            }

            return prng_.?.random().uintAtMost(u64, std.math.maxInt(u64));
        }
    };

    return pcrng.get();
}

pub fn hashWithSeed(seed: u64, content: []const u8) u64 {
    return std.hash.Wyhash.hash(seed, content);
}

pub fn hash32(content: []const u8) u32 {
    const res = hash(content);
    return @as(u32, @truncate(res));
}

pub const HiveArray = @import("./hive_array.zig").HiveArray;

pub fn csprng(bytes: []u8) void {
    _ = BoringSSL.c.RAND_bytes(bytes.ptr, bytes.len);
}

pub const ObjectPool = @import("./pool.zig").ObjectPool;

pub fn assertNonBlocking(fd: anytype) void {
    assert((std.posix.fcntl(fd, std.posix.F.GETFL, 0) catch unreachable) & O.NONBLOCK != 0);
}

pub fn ensureNonBlocking(fd: anytype) void {
    const current = std.posix.fcntl(fd, std.posix.F.GETFL, 0) catch 0;
    _ = std.posix.fcntl(fd, std.posix.F.SETFL, current | O.NONBLOCK) catch 0;
}

const global_scope_log = sys.syslog;
pub fn isReadable(fd: FileDescriptor) PollFlag {
    if (comptime Environment.isWindows) {
        @panic("TODO on Windows");
    }
    assert(fd != invalid_fd);
    var polls = [_]std.posix.pollfd{
        .{
            .fd = fd.cast(),
            .events = std.posix.POLL.IN | std.posix.POLL.ERR | std.posix.POLL.HUP,
            .revents = 0,
        },
    };

    const result = (std.posix.poll(&polls, 0) catch 0) != 0;
    const rc = if (result and polls[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0)
        PollFlag.hup
    else if (result)
        PollFlag.ready
    else
        PollFlag.not_ready;
    global_scope_log("poll({}, .readable): {any} ({s}{s})", .{
        fd,
        result,
        @tagName(rc),
        if (polls[0].revents & std.posix.POLL.ERR != 0) " ERR " else "",
    });
    return rc;
}

pub const PollFlag = enum { ready, not_ready, hup };
pub fn isWritable(fd: FileDescriptor) PollFlag {
    if (comptime Environment.isWindows) {
        var polls = [_]std.os.windows.ws2_32.WSAPOLLFD{
            .{
                .fd = socketcast(fd),
                .events = std.posix.POLL.WRNORM,
                .revents = 0,
            },
        };
        const rc = std.os.windows.ws2_32.WSAPoll(&polls, 1, 0);
        const result = (if (rc != std.os.windows.ws2_32.SOCKET_ERROR) @as(usize, @intCast(rc)) else 0) != 0;
        global_scope_log("poll({}) writable: {any} ({d})", .{ fd, result, polls[0].revents });
        if (result and polls[0].revents & std.posix.POLL.WRNORM != 0) {
            return .hup;
        } else if (result) {
            return .ready;
        } else {
            return .not_ready;
        }
        return;
    }
    assert(fd != invalid_fd);

    var polls = [_]std.posix.pollfd{
        .{
            .fd = fd.cast(),
            .events = std.posix.POLL.OUT | std.posix.POLL.ERR | std.posix.POLL.HUP,
            .revents = 0,
        },
    };

    const result = (std.posix.poll(&polls, 0) catch 0) != 0;
    const rc = if (result and polls[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0)
        PollFlag.hup
    else if (result)
        PollFlag.ready
    else
        PollFlag.not_ready;
    global_scope_log("poll({}, .writable): {any} ({s}{s})", .{
        fd,
        result,
        @tagName(rc),
        if (polls[0].revents & std.posix.POLL.ERR != 0) " ERR " else "",
    });
    return rc;
}

/// Do not use this function, call std.debug.panic directly.
///
/// This function used to panic in debug, and be `unreachable` in release
/// however, if something is possibly reachable, it should not be marked unreachable.
/// It now panics in all release modes.
pub inline fn unreachablePanic(comptime fmts: []const u8, args: anytype) noreturn {
    // if (comptime !Environment.allow_assert) unreachable;
    std.debug.panic(fmts, args);
}

pub fn StringEnum(comptime Type: type, comptime Map: anytype, value: []const u8) ?Type {
    return ComptimeStringMap(Type, Map).get(value);
}

pub const Bunfig = @import("./bunfig.zig").Bunfig;

pub const HTTPThread = @import("./http.zig").HTTPThread;
pub const http = @import("./http.zig");

pub const Analytics = @import("./analytics/analytics_thread.zig");

pub const TaggedPointer = ptr.TaggedPointer;
pub const TaggedPointerUnion = ptr.TaggedPointerUnion;

pub fn onceUnsafe(comptime function: anytype, comptime ReturnType: type) ReturnType {
    const Result = struct {
        var value: ReturnType = undefined;
        var ran = false;

        pub fn execute() ReturnType {
            if (ran) return value;
            ran = true;
            value = function();
            return value;
        }
    };

    return Result.execute();
}

pub fn isHeapMemory(memory: anytype) bool {
    if (comptime use_mimalloc) {
        const Memory = @TypeOf(memory);
        if (comptime std.meta.trait.isSingleItemPtr(Memory)) {
            return Mimalloc.mi_is_in_heap_region(memory);
        }
        return Mimalloc.mi_is_in_heap_region(std.mem.sliceAsBytes(memory).ptr);
    }
    return false;
}

pub const Mimalloc = @import("allocators/mimalloc.zig");
pub const AllocationScope = @import("allocators/AllocationScope.zig");

pub const isSliceInBuffer = allocators.isSliceInBuffer;
pub const isSliceInBufferT = allocators.isSliceInBufferT;

pub inline fn sliceInBuffer(stable: string, value: string) string {
    if (allocators.sliceRange(stable, value)) |_| {
        return value;
    }
    if (strings.indexOf(stable, value)) |index| {
        return stable[index..][0..value.len];
    }
    return value;
}

pub fn rangeOfSliceInBuffer(slice: []const u8, buffer: []const u8) ?[2]u32 {
    if (!isSliceInBuffer(slice, buffer)) return null;
    const r = [_]u32{
        @as(u32, @truncate(@intFromPtr(slice.ptr) -| @intFromPtr(buffer.ptr))),
        @as(u32, @truncate(slice.len)),
    };
    if (comptime Environment.allow_assert)
        assert(strings.eqlLong(slice, buffer[r[0]..][0..r[1]], false));
    return r;
}

/// on unix, this == std.math.maxInt(i32)
/// on windows, this is encode(.{ .system, std.math.maxInt(u63) })
pub const invalid_fd: FileDescriptor = FDImpl.invalid.encode();

pub const simdutf = @import("./bun.js/bindings/bun-simdutf.zig");

pub const JSC = @import("jsc.zig");

pub const logger = @import("./logger.zig");
pub const ThreadPool = @import("./thread_pool.zig");
pub const default_thread_stack_size = ThreadPool.default_thread_stack_size;
pub const picohttp = @import("./deps/picohttp.zig");
pub const uws = @import("./deps/uws.zig");
pub const BoringSSL = @import("./boringssl.zig");
pub const LOLHTML = @import("./deps/lol-html.zig");
pub const clap = @import("./deps/zig-clap/clap.zig");
pub const analytics = @import("./analytics/analytics_thread.zig");
pub const zlib = @import("./zlib.zig");

pub var start_time: i128 = 0;

pub fn openFileZ(pathZ: [:0]const u8, open_flags: std.fs.File.OpenFlags) !std.fs.File {
    var flags: i32 = 0;
    switch (open_flags.mode) {
        .read_only => flags |= O.RDONLY,
        .write_only => flags |= O.WRONLY,
        .read_write => flags |= O.RDWR,
    }

    const res = try sys.open(pathZ, flags, 0).unwrap();
    return std.fs.File{ .handle = res.cast() };
}

pub fn openFile(path_: []const u8, open_flags: std.fs.File.OpenFlags) !std.fs.File {
    if (comptime Environment.isWindows) {
        var flags: i32 = 0;
        switch (open_flags.mode) {
            .read_only => flags |= O.RDONLY,
            .write_only => flags |= O.WRONLY,
            .read_write => flags |= O.RDWR,
        }

        const fd = try sys.openA(path_, flags, 0).unwrap();
        return fd.asFile();
    }

    return try openFileZ(&try std.posix.toPosixPath(path_), open_flags);
}

pub fn openDir(dir: std.fs.Dir, path_: [:0]const u8) !std.fs.Dir {
    if (comptime Environment.isWindows) {
        const res = try sys.openDirAtWindowsA(toFD(dir.fd), path_, .{ .iterable = true, .can_rename_or_delete = true, .read_only = true }).unwrap();
        return res.asDir();
    } else {
        const fd = try sys.openat(toFD(dir.fd), path_, O.DIRECTORY | O.CLOEXEC | O.RDONLY, 0).unwrap();
        return fd.asDir();
    }
}

pub fn openDirNoRenamingOrDeletingWindows(dir: FileDescriptor, path_: [:0]const u8) !std.fs.Dir {
    if (comptime !Environment.isWindows) @compileError("use openDir!");
    const res = try sys.openDirAtWindowsA(dir, path_, .{ .iterable = true, .can_rename_or_delete = false, .read_only = true }).unwrap();
    return res.asDir();
}

pub fn openDirA(dir: std.fs.Dir, path_: []const u8) !std.fs.Dir {
    if (comptime Environment.isWindows) {
        const res = try sys.openDirAtWindowsA(toFD(dir.fd), path_, .{ .iterable = true, .can_rename_or_delete = true, .read_only = true }).unwrap();
        return res.asDir();
    } else {
        const fd = try sys.openatA(toFD(dir.fd), path_, O.DIRECTORY | O.CLOEXEC | O.RDONLY, 0).unwrap();
        return fd.asDir();
    }
}

pub fn openDirForIteration(dir: std.fs.Dir, path_: []const u8) !std.fs.Dir {
    if (comptime Environment.isWindows) {
        const res = try sys.openDirAtWindowsA(toFD(dir.fd), path_, .{ .iterable = true, .can_rename_or_delete = false, .read_only = true }).unwrap();
        return res.asDir();
    } else {
        const fd = try sys.openatA(toFD(dir.fd), path_, O.DIRECTORY | O.CLOEXEC | O.RDONLY, 0).unwrap();
        return fd.asDir();
    }
}

pub fn openDirAbsolute(path_: []const u8) !std.fs.Dir {
    const fd = if (comptime Environment.isWindows)
        try sys.openDirAtWindowsA(invalid_fd, path_, .{ .iterable = true, .can_rename_or_delete = true, .read_only = true }).unwrap()
    else
        try sys.openA(path_, O.DIRECTORY | O.CLOEXEC | O.RDONLY, 0).unwrap();

    return fd.asDir();
}

pub fn openDirAbsoluteNotForDeletingOrRenaming(path_: []const u8) !std.fs.Dir {
    const fd = if (comptime Environment.isWindows)
        try sys.openDirAtWindowsA(invalid_fd, path_, .{ .iterable = true, .can_rename_or_delete = false, .read_only = true }).unwrap()
    else
        try sys.openA(path_, O.DIRECTORY | O.CLOEXEC | O.RDONLY, 0).unwrap();

    return fd.asDir();
}

pub const MimallocArena = @import("./allocators/mimalloc_arena.zig").Arena;
pub fn getRuntimeFeatureFlag(comptime flag: [:0]const u8) bool {
    return struct {
        const state = enum(u8) { idk, disabled, enabled };
        var is_enabled: std.atomic.Value(state) = std.atomic.Value(state).init(.idk);
        pub fn get() bool {
            return switch (is_enabled.load(.seq_cst)) {
                .enabled => true,
                .disabled => false,
                .idk => {
                    const enabled = if (getenvZ(flag)) |val|
                        strings.eqlComptime(val, "1") or strings.eqlComptime(val, "true")
                    else
                        false;
                    is_enabled.store(if (enabled) .enabled else .disabled, .seq_cst);
                    return enabled;
                },
            };
        }
    }.get();
}

pub fn getenvZAnyCase(key: [:0]const u8) ?[]const u8 {
    for (std.os.environ) |lineZ| {
        const line = sliceTo(lineZ, 0);
        const key_end = strings.indexOfCharUsize(line, '=') orelse line.len;
        if (strings.eqlCaseInsensitiveASCII(line[0..key_end], key, true)) {
            return line[@min(key_end + 1, line.len)..];
        }
    }

    return null;
}

/// This wrapper exists to avoid the call to sliceTo(0)
/// Zig's sliceTo(0) is scalar
pub fn getenvZ(key: [:0]const u8) ?[]const u8 {
    if (comptime !Environment.isNative) {
        return null;
    }

    if (comptime Environment.isWindows) {
        return getenvZAnyCase(key);
    }

    const pointer = std.c.getenv(key.ptr) orelse return null;
    return sliceTo(pointer, 0);
}

pub fn getenvTruthy(key: [:0]const u8) bool {
    if (getenvZ(key)) |value| return std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1");
    return false;
}

pub const FDHashMapContext = struct {
    pub fn hash(_: @This(), fd: FileDescriptor) u64 {
        // a file descriptor is i32 on linux, u64 on windows
        // the goal here is to do zero work and widen the 32 bit type to 64
        // this should compile error if FileDescriptor somehow is larger than 64 bits.
        comptime assert(@bitSizeOf(FileDescriptor) <= 64);
        return @intCast(fd.int());
    }
    pub fn eql(_: @This(), a: FileDescriptor, b: FileDescriptor) bool {
        return a == b;
    }
    pub fn pre(input: FileDescriptor) Prehashed {
        return Prehashed{
            .value = @This().hash(.{}, input),
            .input = input,
        };
    }

    pub const Prehashed = struct {
        value: u64,
        input: FileDescriptor,
        pub fn hash(this: @This(), fd: FileDescriptor) u64 {
            if (fd == this.input) return this.value;
            return fd;
        }

        pub fn eql(_: @This(), a: FileDescriptor, b: FileDescriptor) bool {
            return a == b;
        }
    };
};

pub const U32HashMapContext = struct {
    pub fn hash(_: @This(), value: u32) u64 {
        return @intCast(value);
    }
    pub fn eql(_: @This(), a: u32, b: u32) bool {
        return a == b;
    }
    pub fn pre(input: u32) Prehashed {
        return Prehashed{
            .value = @This().hash(.{}, input),
            .input = input,
        };
    }

    pub const Prehashed = struct {
        value: u64,
        input: u32,
        pub fn hash(this: @This(), value: u32) u64 {
            if (value == this.input) return this.value;
            return @intCast(value);
        }

        pub fn eql(_: @This(), a: u32, b: u32) bool {
            return a == b;
        }
    };
};
// These wrappers exist to use our strings.eqlLong function
pub const StringArrayHashMapContext = struct {
    pub fn hash(_: @This(), s: []const u8) u32 {
        return @as(u32, @truncate(std.hash.Wyhash.hash(0, s)));
    }
    pub fn eql(_: @This(), a: []const u8, b: []const u8, _: usize) bool {
        return strings.eqlLong(a, b, true);
    }

    pub fn pre(input: []const u8) Prehashed {
        return Prehashed{
            .value = @This().hash(.{}, input),
            .input = input,
        };
    }

    pub const Prehashed = struct {
        value: u32,
        input: []const u8,

        pub fn hash(this: @This(), s: []const u8) u32 {
            if (s.ptr == this.input.ptr and s.len == this.input.len)
                return this.value;
            return @as(u32, @truncate(std.hash.Wyhash.hash(0, s)));
        }

        pub fn eql(_: @This(), a: []const u8, b: []const u8, _: usize) bool {
            return strings.eqlLong(a, b, true);
        }
    };
};

pub const CaseInsensitiveASCIIStringContext = struct {
    pub fn hash(_: @This(), str_: []const u8) u32 {
        var buf: [1024]u8 = undefined;
        if (str_.len < buf.len) {
            return @truncate(std.hash.Wyhash.hash(0, strings.copyLowercase(str_, &buf)));
        }
        var str = str_;
        var wyhash = std.hash.Wyhash.init(0);
        while (str.len > 0) {
            const length = @min(str.len, buf.len);
            wyhash.update(strings.copyLowercase(str[0..length], &buf));
            str = str[length..];
        }
        return @truncate(wyhash.final());
    }

    pub fn eql(_: @This(), a: []const u8, b: []const u8, _: usize) bool {
        return strings.eqlCaseInsensitiveASCIIICheckLength(a, b);
    }

    pub fn pre(input: []const u8) Prehashed {
        return Prehashed{
            .value = @This().hash(.{}, input),
            .input = input,
        };
    }

    pub const Prehashed = struct {
        value: u32,
        input: []const u8,

        pub fn hash(this: @This(), s: []const u8) u32 {
            if (s.ptr == this.input.ptr and s.len == this.input.len)
                return this.value;
            return CaseInsensitiveASCIIStringContext.hash(.{}, s);
        }

        pub fn eql(_: @This(), a: []const u8, b: []const u8) bool {
            return strings.eqlCaseInsensitiveASCIIICheckLength(a, b);
        }
    };
};

pub const StringHashMapContext = struct {
    pub fn hash(_: @This(), s: []const u8) u64 {
        return std.hash.Wyhash.hash(0, s);
    }
    pub fn eql(_: @This(), a: []const u8, b: []const u8) bool {
        return strings.eqlLong(a, b, true);
    }

    pub fn pre(input: []const u8) Prehashed {
        return Prehashed{
            .value = @This().hash(.{}, input),
            .input = input,
        };
    }

    pub const Prehashed = struct {
        value: u64,
        input: []const u8,
        pub fn hash(this: @This(), s: []const u8) u64 {
            if (s.ptr == this.input.ptr and s.len == this.input.len)
                return this.value;
            return StringHashMapContext.hash(.{}, s);
        }

        pub fn eql(_: @This(), a: []const u8, b: []const u8) bool {
            return strings.eqlLong(a, b, true);
        }
    };

    pub const PrehashedCaseInsensitive = struct {
        value: u64,
        input: []const u8,
        pub fn init(allocator: std.mem.Allocator, input: []const u8) PrehashedCaseInsensitive {
            const out = allocator.alloc(u8, input.len) catch unreachable;
            _ = strings.copyLowercase(input, out);
            return PrehashedCaseInsensitive{
                .value = StringHashMapContext.hash(.{}, out),
                .input = out,
            };
        }
        pub fn deinit(this: @This(), allocator: std.mem.Allocator) void {
            allocator.free(this.input);
        }
        pub fn hash(this: @This(), s: []const u8) u64 {
            if (s.ptr == this.input.ptr and s.len == this.input.len)
                return this.value;
            return StringHashMapContext.hash(.{}, s);
        }

        pub fn eql(_: @This(), a: []const u8, b: []const u8) bool {
            return strings.eqlCaseInsensitiveASCIIICheckLength(a, b);
        }
    };
};

pub fn StringArrayHashMap(comptime Type: type) type {
    return std.ArrayHashMap([]const u8, Type, StringArrayHashMapContext, true);
}

pub fn CaseInsensitiveASCIIStringArrayHashMap(comptime Type: type) type {
    return std.ArrayHashMap([]const u8, Type, CaseInsensitiveASCIIStringContext, true);
}

pub fn CaseInsensitiveASCIIStringArrayHashMapUnmanaged(comptime Type: type) type {
    return std.ArrayHashMapUnmanaged([]const u8, Type, CaseInsensitiveASCIIStringContext, true);
}

pub fn StringArrayHashMapUnmanaged(comptime Type: type) type {
    return std.ArrayHashMapUnmanaged([]const u8, Type, StringArrayHashMapContext, true);
}

pub fn StringHashMap(comptime Type: type) type {
    return std.HashMap([]const u8, Type, StringHashMapContext, std.hash_map.default_max_load_percentage);
}

pub fn StringHashMapUnmanaged(comptime Type: type) type {
    return std.HashMapUnmanaged([]const u8, Type, StringHashMapContext, std.hash_map.default_max_load_percentage);
}

pub fn FDHashMap(comptime Type: type) type {
    return std.HashMap(StoredFileDescriptorType, Type, FDHashMapContext, std.hash_map.default_max_load_percentage);
}

pub fn U32HashMap(comptime Type: type) type {
    return std.HashMap(u32, Type, U32HashMapContext, std.hash_map.default_max_load_percentage);
}

const CopyFile = @import("./copy_file.zig");
pub const copyFileErrnoConvert = CopyFile.copyFileErrorConvert;
pub const copyFileRange = CopyFile.copyFileRange;
pub const canUseCopyFileRangeSyscall = CopyFile.canUseCopyFileRangeSyscall;
pub const disableCopyFileRangeSyscall = CopyFile.disableCopyFileRangeSyscall;
pub const can_use_ioctl_ficlone = CopyFile.can_use_ioctl_ficlone;
pub const disable_ioctl_ficlone = CopyFile.disable_ioctl_ficlone;
pub const copyFile = CopyFile.copyFile;
pub const copyFileWithState = CopyFile.copyFileWithState;
pub const CopyFileState = CopyFile.CopyFileState;

pub fn parseDouble(input: []const u8) !f64 {
    if (comptime Environment.isWasm) {
        return try std.fmt.parseFloat(f64, input);
    }
    return JSC.WTF.parseDouble(input);
}

pub const SignalCode = enum(u8) {
    SIGHUP = 1,
    SIGINT = 2,
    SIGQUIT = 3,
    SIGILL = 4,
    SIGTRAP = 5,
    SIGABRT = 6,
    SIGBUS = 7,
    SIGFPE = 8,
    SIGKILL = 9,
    SIGUSR1 = 10,
    SIGSEGV = 11,
    SIGUSR2 = 12,
    SIGPIPE = 13,
    SIGALRM = 14,
    SIGTERM = 15,
    SIG16 = 16,
    SIGCHLD = 17,
    SIGCONT = 18,
    SIGSTOP = 19,
    SIGTSTP = 20,
    SIGTTIN = 21,
    SIGTTOU = 22,
    SIGURG = 23,
    SIGXCPU = 24,
    SIGXFSZ = 25,
    SIGVTALRM = 26,
    SIGPROF = 27,
    SIGWINCH = 28,
    SIGIO = 29,
    SIGPWR = 30,
    SIGSYS = 31,
    _,

    // The `subprocess.kill()` method sends a signal to the child process. If no
    // argument is given, the process will be sent the 'SIGTERM' signal.
    pub const default = SignalCode.SIGTERM;
    pub const Map = ComptimeEnumMap(SignalCode);
    pub fn name(value: SignalCode) ?[]const u8 {
        if (@intFromEnum(value) <= @intFromEnum(SignalCode.SIGSYS)) {
            return asByteSlice(@tagName(value));
        }

        return null;
    }

    pub fn valid(value: SignalCode) bool {
        return @intFromEnum(value) <= @intFromEnum(SignalCode.SIGSYS) and @intFromEnum(value) >= @intFromEnum(SignalCode.SIGHUP);
    }

    /// Shell scripts use exit codes 128 + signal number
    /// https://tldp.org/LDP/abs/html/exitcodes.html
    pub fn toExitCode(value: SignalCode) ?u8 {
        return switch (@intFromEnum(value)) {
            1...31 => 128 +% @intFromEnum(value),
            else => null,
        };
    }

    pub fn description(signal: SignalCode) ?[]const u8 {
        // Description names copied from fish
        // https://github.com/fish-shell/fish-shell/blob/00ffc397b493f67e28f18640d3de808af29b1434/fish-rust/src/signal.rs#L420
        return switch (signal) {
            .SIGHUP => "Terminal hung up",
            .SIGINT => "Quit request",
            .SIGQUIT => "Quit request",
            .SIGILL => "Illegal instruction",
            .SIGTRAP => "Trace or breakpoint trap",
            .SIGABRT => "Abort",
            .SIGBUS => "Misaligned address error",
            .SIGFPE => "Floating point exception",
            .SIGKILL => "Forced quit",
            .SIGUSR1 => "User defined signal 1",
            .SIGUSR2 => "User defined signal 2",
            .SIGSEGV => "Address boundary error",
            .SIGPIPE => "Broken pipe",
            .SIGALRM => "Timer expired",
            .SIGTERM => "Polite quit request",
            .SIGCHLD => "Child process status changed",
            .SIGCONT => "Continue previously stopped process",
            .SIGSTOP => "Forced stop",
            .SIGTSTP => "Stop request from job control (^Z)",
            .SIGTTIN => "Stop from terminal input",
            .SIGTTOU => "Stop from terminal output",
            .SIGURG => "Urgent socket condition",
            .SIGXCPU => "CPU time limit exceeded",
            .SIGXFSZ => "File size limit exceeded",
            .SIGVTALRM => "Virtual timefr expired",
            .SIGPROF => "Profiling timer expired",
            .SIGWINCH => "Window size change",
            .SIGIO => "I/O on asynchronous file descriptor is possible",
            .SIGSYS => "Bad system call",
            .SIGPWR => "Power failure",
            else => null,
        };
    }

    pub fn from(value: anytype) SignalCode {
        return @enumFromInt(std.mem.asBytes(&value)[0]);
    }

    // This wrapper struct is lame, what if bun's color formatter was more versatile
    const Fmt = struct {
        signal: SignalCode,
        enable_ansi_colors: bool,
        pub fn format(this: Fmt, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            const signal = this.signal;
            switch (this.enable_ansi_colors) {
                inline else => |enable_ansi_colors| {
                    if (signal.name()) |str| if (signal.description()) |desc| {
                        try writer.print(Output.prettyFmt("{s} <d>({s})<r>", enable_ansi_colors), .{ str, desc });
                        return;
                    };
                    try writer.print("code {d}", .{@intFromEnum(signal)});
                },
            }
        }
    };

    pub fn fmt(signal: SignalCode, enable_ansi_colors: bool) Fmt {
        return .{ .signal = signal, .enable_ansi_colors = enable_ansi_colors };
    }
};

pub fn isMissingIOUring() bool {
    if (comptime !Environment.isLinux)
        // it is not missing when it was not supposed to be there in the first place
        return false;

    // cache the boolean value
    const Missing = struct {
        pub var is_missing_io_uring: ?bool = null;
    };

    return Missing.is_missing_io_uring orelse brk: {
        const kernel = Analytics.GenerateHeader.GeneratePlatform.kernelVersion();
        // io_uring was introduced in earlier versions of Linux, but it was not
        // really usable for us until 5.3
        const result = kernel.major < 5 or (kernel.major == 5 and kernel.minor < 3);
        Missing.is_missing_io_uring = result;
        break :brk result;
    };
}

pub const CLI = @import("./cli.zig");

pub const install = @import("./install/install.zig");
pub const PackageManager = install.PackageManager;
pub const RunCommand = @import("./cli/run_command.zig").RunCommand;

pub const fs = @import("./fs.zig");
pub const Transpiler = transpiler.Transpiler;
pub const transpiler = @import("./transpiler.zig");
pub const which = @import("./which.zig").which;
pub const js_parser = @import("./js_parser.zig");
pub const js_printer = @import("./js_printer.zig");
pub const js_lexer = @import("./js_lexer.zig");
pub const JSON = @import("./json_parser.zig");
pub const JSAst = @import("./js_ast.zig");
pub const bit_set = @import("./bit_set.zig");

pub fn enumMap(comptime T: type, comptime args: anytype) (fn (T) [:0]const u8) {
    const Map = struct {
        const vargs = args;
        const labels = brk: {
            var vabels_ = std.enums.EnumArray(T, [:0]const u8).initFill("");
            @setEvalBranchQuota(99999);
            for (vargs) |field| {
                vabels_.set(field.@"0", field.@"1");
            }
            break :brk vabels_;
        };

        pub fn get(input: T) [:0]const u8 {
            return labels.get(input);
        }
    };

    return Map.get;
}

pub fn ComptimeEnumMap(comptime T: type) type {
    var entries: [std.enums.values(T).len]struct { [:0]const u8, T } = undefined;
    for (std.enums.values(T), &entries) |value, *entry| {
        entry.* = .{ .@"0" = @tagName(value), .@"1" = value };
    }
    return ComptimeStringMap(T, entries);
}

/// Write 0's for every byte in Type
/// Ignores default struct values.
pub fn zero(comptime Type: type) Type {
    var out: [@sizeOf(Type)]u8 align(@alignOf(Type)) = undefined;
    @memset(@as([*]u8, @ptrCast(&out))[0..out.len], 0);
    return @as(Type, @bitCast(out));
}
pub const c_ares = @import("./deps/c_ares.zig");
pub const URL = @import("./url.zig").URL;
pub const FormData = @import("./url.zig").FormData;

var needs_proc_self_workaround: bool = false;

// This is our "polyfill" when /proc/self/fd is not available it's only
// necessary on linux because other platforms don't have an optional
// /proc/self/fd
fn getFdPathViaCWD(fd: std.posix.fd_t, buf: *[@This().MAX_PATH_BYTES]u8) ![]u8 {
    const prev_fd = try std.posix.openatZ(std.fs.cwd().fd, ".", .{ .DIRECTORY = true }, 0);
    var needs_chdir = false;
    defer {
        if (needs_chdir) std.posix.fchdir(prev_fd) catch unreachable;
        std.posix.close(prev_fd);
    }
    try std.posix.fchdir(fd);
    needs_chdir = true;
    return std.posix.getcwd(buf);
}

pub const getcwd = std.posix.getcwd;

pub fn getcwdAlloc(allocator: std.mem.Allocator) ![:0]u8 {
    var temp: PathBuffer = undefined;
    const temp_slice = try getcwd(&temp);
    return allocator.dupeZ(u8, temp_slice);
}

/// Get the absolute path to a file descriptor.
/// On Linux, when `/proc/self/fd` is not available, this function will attempt to use `fchdir` and `getcwd` to get the path instead.
pub fn getFdPath(fd_: anytype, buf: *[MAX_PATH_BYTES]u8) ![]u8 {
    const fd = toFD(fd_).cast();

    if (comptime Environment.isWindows) {
        var wide_buf: WPathBuffer = undefined;
        const wide_slice = try windows.GetFinalPathNameByHandle(fd, .{}, wide_buf[0..]);
        const res = strings.copyUTF16IntoUTF8(buf[0..], @TypeOf(wide_slice), wide_slice, true);
        return buf[0..res.written];
    }

    if (comptime Environment.allow_assert) {
        // We need a way to test that the workaround is working
        // but we don't want to do this check in a release build
        const ProcSelfWorkAroundForDebugging = struct {
            pub var has_checked = false;
        };

        if (!ProcSelfWorkAroundForDebugging.has_checked) {
            ProcSelfWorkAroundForDebugging.has_checked = true;
            needs_proc_self_workaround = strings.eql(getenvZ("BUN_NEEDS_PROC_SELF_WORKAROUND") orelse "0", "1");
        }
    } else if (comptime !Environment.isLinux) {
        return try std.os.getFdPath(fd, buf);
    }

    if (needs_proc_self_workaround) {
        return getFdPathViaCWD(fd, buf);
    }

    return std.os.getFdPath(fd, buf) catch |err| {
        if (err == error.FileNotFound and !needs_proc_self_workaround) {
            needs_proc_self_workaround = true;
            return getFdPathViaCWD(fd, buf);
        }

        return err;
    };
}

pub fn getFdPathZ(fd_: anytype, buf: *PathBuffer) ![:0]u8 {
    const path_ = try getFdPath(fd_, buf);
    buf[path_.len] = 0;
    return buf[0..path_.len :0];
}

pub fn getFdPathW(fd_: anytype, buf: *WPathBuffer) ![]u16 {
    const fd = toFD(fd_).cast();

    if (comptime Environment.isWindows) {
        const wide_slice = try windows.GetFinalPathNameByHandle(fd, .{}, buf);

        return wide_slice;
    }

    @panic("TODO unsupported platform for getFdPathW");
}

fn lenSliceTo(pointer: anytype, comptime end: std.meta.Elem(@TypeOf(pointer))) usize {
    switch (@typeInfo(@TypeOf(pointer))) {
        .pointer => |ptr_info| switch (ptr_info.size) {
            .one => switch (@typeInfo(ptr_info.child)) {
                .array => |array_info| {
                    if (array_info.sentinel_ptr) |sentinel_ptr| {
                        const sentinel = @as(*align(1) const array_info.child, @ptrCast(sentinel_ptr)).*;
                        if (sentinel == end) {
                            return std.mem.indexOfSentinel(array_info.child, end, pointer);
                        }
                    }
                    return std.mem.indexOfScalar(array_info.child, pointer, end) orelse array_info.len;
                },
                else => {},
            },
            .many => if (ptr_info.sentinel_ptr) |sentinel_ptr| {
                const sentinel = @as(*align(1) const ptr_info.child, @ptrCast(sentinel_ptr)).*;
                // We may be looking for something other than the sentinel,
                // but iterating past the sentinel would be a bug so we need
                // to check for both.
                var i: usize = 0;
                while (pointer[i] != end and pointer[i] != sentinel) i += 1;
                return i;
            },
            .c => {
                assert(pointer != null);
                return std.mem.indexOfSentinel(ptr_info.child, end, pointer);
            },
            .slice => {
                if (ptr_info.sentinel_ptr) |sentinel_ptr| {
                    const sentinel = @as(*align(1) const ptr_info.child, @ptrCast(sentinel_ptr)).*;
                    if (sentinel == end) {
                        return std.mem.indexOfSentinel(ptr_info.child, sentinel, pointer);
                    }
                }
                return std.mem.indexOfScalar(ptr_info.child, pointer, end) orelse pointer.len;
            },
        },
        else => {},
    }
    @compileError("invalid type given to std.mem.sliceTo: " ++ @typeName(@TypeOf(pointer)));
}

/// Helper for the return type of sliceTo()
fn SliceTo(comptime T: type, comptime end: std.meta.Elem(T)) type {
    switch (@typeInfo(T)) {
        .optional => |optional_info| {
            return ?SliceTo(optional_info.child, end);
        },
        .pointer => |ptr_info| {
            var new_ptr_info = ptr_info;
            new_ptr_info.size = .slice;
            switch (ptr_info.size) {
                .one => switch (@typeInfo(ptr_info.child)) {
                    .array => |array_info| {
                        new_ptr_info.child = array_info.child;
                        // The return type must only be sentinel terminated if we are guaranteed
                        // to find the value searched for, which is only the case if it matches
                        // the sentinel of the type passed.
                        if (array_info.sentinel_ptr) |sentinel_ptr| {
                            const sentinel = @as(*align(1) const array_info.child, @ptrCast(sentinel_ptr)).*;
                            if (end == sentinel) {
                                new_ptr_info.sentinel_ptr = &end;
                            } else {
                                new_ptr_info.sentinel_ptr = null;
                            }
                        }
                    },
                    else => {},
                },
                .many, .slice => {
                    // The return type must only be sentinel terminated if we are guaranteed
                    // to find the value searched for, which is only the case if it matches
                    // the sentinel of the type passed.
                    if (ptr_info.sentinel_ptr) |sentinel_ptr| {
                        const sentinel = @as(*align(1) const ptr_info.child, @ptrCast(sentinel_ptr)).*;
                        if (end == sentinel) {
                            new_ptr_info.sentinel_ptr = &end;
                        } else {
                            new_ptr_info.sentinel_ptr = null;
                        }
                    }
                },
                .c => {
                    new_ptr_info.sentinel_ptr = &end;
                    // C pointers are always allowzero, but we don't want the return type to be.
                    assert(new_ptr_info.is_allowzero);
                    new_ptr_info.is_allowzero = false;
                },
            }
            return @Type(.{ .pointer = new_ptr_info });
        },
        else => {},
    }
    @compileError("invalid type given to std.mem.sliceTo: " ++ @typeName(T));
}

/// Takes an array, a pointer to an array, a sentinel-terminated pointer, or a slice and
/// iterates searching for the first occurrence of `end`, returning the scanned slice.
/// If `end` is not found, the full length of the array/slice/sentinel terminated pointer is returned.
/// If the pointer type is sentinel terminated and `end` matches that terminator, the
/// resulting slice is also sentinel terminated.
/// Pointer properties such as mutability and alignment are preserved.
/// C pointers are assumed to be non-null.
pub fn sliceTo(pointer: anytype, comptime end: std.meta.Elem(@TypeOf(pointer))) SliceTo(@TypeOf(pointer), end) {
    if (@typeInfo(@TypeOf(pointer)) == .optional) {
        const non_null = pointer orelse return null;
        return sliceTo(non_null, end);
    }
    const Result = SliceTo(@TypeOf(pointer), end);
    const length = lenSliceTo(pointer, end);
    const ptr_info = @typeInfo(Result).pointer;
    if (ptr_info.sentinel_ptr) |s_ptr| {
        const s = @as(*align(1) const ptr_info.child, @ptrCast(s_ptr)).*;
        return pointer[0..length :s];
    } else {
        return pointer[0..length];
    }
}

pub const Semver = @import("./semver.zig");
pub const ImportRecord = @import("./import_record.zig").ImportRecord;
pub const ImportKind = @import("./import_record.zig").ImportKind;

pub const Watcher = @import("./Watcher.zig");

pub fn concat(comptime T: type, dest: []T, src: []const []const T) void {
    var remain = dest;
    for (src) |group| {
        bun.copy(T, remain[0..group.len], group);
        remain = remain[group.len..];
    }
}

pub const fast_debug_build_cmd = .None;
pub const fast_debug_build_mode = fast_debug_build_cmd != .None and
    Environment.isDebug;

pub const MultiArrayList = @import("./multi_array_list.zig").MultiArrayList;
pub const NullableAllocator = @import("./allocators/NullableAllocator.zig");

pub const renamer = @import("./renamer.zig");
// TODO: Rename to SourceMap as this is a struct.
pub const sourcemap = @import("./sourcemap/sourcemap.zig");

/// Attempt to coerce some value into a byte slice.
pub fn asByteSlice(buffer: anytype) []const u8 {
    return switch (@TypeOf(buffer)) {
        [*:0]u8, [*:0]const u8 => buffer[0..len(buffer)],
        [*c]const u8, [*c]u8 => span(buffer),

        else => buffer, // attempt to coerce to []const u8
    };
}

comptime {
    if (fast_debug_build_cmd != .RunCommand and fast_debug_build_mode) {
        _ = @import("./bun.js/node/buffer.zig").BufferVectorized.fill;
        _ = @import("./cli/upgrade_command.zig").Version;
    }
}

pub fn DebugOnlyDisabler(comptime Type: type) type {
    return struct {
        const T = Type;
        threadlocal var disable_create_in_debug: if (Environment.isDebug) usize else u0 = 0;
        pub inline fn disable() void {
            if (comptime !Environment.isDebug) return;
            disable_create_in_debug += 1;
        }

        pub inline fn enable() void {
            if (comptime !Environment.isDebug) return;
            disable_create_in_debug -= 1;
        }

        pub inline fn assert() void {
            if (comptime !Environment.isDebug) return;
            if (disable_create_in_debug > 0) {
                Output.panic(comptime "[" ++ @typeName(T) ++ "] called while disabled (did you forget to call enable?)", .{});
            }
        }
    };
}

const FailingAllocator = struct {
    fn alloc(_: *anyopaque, _: usize, _: u8, _: usize) ?[*]u8 {
        if (comptime Environment.allow_assert) {
            unreachablePanic("FailingAllocator should never be reached. This means some memory was not defined", .{});
        }
        return null;
    }

    fn resize(_: *anyopaque, _: []u8, _: u8, _: usize, _: usize) bool {
        if (comptime Environment.allow_assert) {
            unreachablePanic("FailingAllocator should never be reached. This means some memory was not defined", .{});
        }
        return false;
    }

    fn free(
        _: *anyopaque,
        _: []u8,
        _: u8,
        _: usize,
    ) void {
        unreachable;
    }
};

/// When we want to avoid initializing a value as undefined, we can use this allocator
pub const failing_allocator = std.mem.Allocator{ .ptr = undefined, .vtable = &.{
    .alloc = FailingAllocator.alloc,
    .resize = FailingAllocator.resize,
    .free = FailingAllocator.free,
} };

var __reload_in_progress__ = std.atomic.Value(bool).init(false);
threadlocal var __reload_in_progress__on_current_thread = false;
pub fn isProcessReloadInProgressOnAnotherThread() bool {
    return __reload_in_progress__.load(.monotonic) and !__reload_in_progress__on_current_thread;
}

pub noinline fn maybeHandlePanicDuringProcessReload() void {
    if (isProcessReloadInProgressOnAnotherThread()) {
        Output.flush();
        if (comptime Environment.isDebug) {
            Output.debugWarn("panic() called during process reload, ignoring\n", .{});
        }

        exitThread();
    }

    // This shouldn't be reachable, but it can technically be because
    // pthread_exit is a request and not guaranteed.
    if (isProcessReloadInProgressOnAnotherThread()) {
        while (true) {
            std.atomic.spinLoopHint();

            if (comptime Environment.isPosix) {
                std.posix.nanosleep(1, 0);
            }
        }
    }
}

extern "c" fn on_before_reload_process_linux() void;

/// Reload Bun's process. This clones envp, argv, and gets the current
/// executable path.
///
/// On posix, this overwrites the current process with the new process using
/// `execve`. On Windows, we dont have this API, instead relying on a dummy
/// parent process that we can signal via a special exit code.
///
/// Must be able to allocate memory. `malloc` is not signal safe, but it's
/// best-effort. Not much we can do if it fails.
///
/// Note that this function is called during the crash handler, in which it is
/// passed true to `may_return`. If failure occurs, one line of standard error
/// is printed and then this returns void. If `may_return == false`, then a
/// panic will occur on failure. The crash handler will not schedule two reloads
/// at once.
pub fn reloadProcess(
    allocator: std.mem.Allocator,
    clear_terminal: bool,
    comptime may_return: bool,
) if (may_return) void else noreturn {
    __reload_in_progress__.store(true, .monotonic);
    __reload_in_progress__on_current_thread = true;

    if (clear_terminal) {
        Output.flush();
        Output.disableBuffering();
        Output.resetTerminalAll();
    }

    Output.Source.Stdio.restore();

    if (comptime Environment.isWindows) {
        // on windows we assume that we have a parent process that is monitoring us and will restart us if we exit with a magic exit code
        // see becomeWatcherManager
        const rc = bun.windows.TerminateProcess(bun.windows.GetCurrentProcess(), win32.watcher_reload_exit);
        if (rc == 0) {
            const err = bun.windows.GetLastError();
            if (may_return) {
                Output.errGeneric("Failed to reload process: {s}", .{@tagName(err)});
                return;
            }
            Output.panic("Error while reloading process: {s}", .{@tagName(err)});
        } else {
            if (may_return) {
                Output.errGeneric("Failed to reload process", .{});
                return;
            }
            Output.panic("Unexpected error while reloading process\n", .{});
        }
    }

    const PosixSpawn = posix.spawn;
    const dupe_argv = allocator.allocSentinel(?[*:0]const u8, bun.argv.len, null) catch unreachable;
    for (bun.argv, dupe_argv) |src, *dest| {
        dest.* = (allocator.dupeZ(u8, src) catch unreachable).ptr;
    }

    const environ_slice = std.mem.span(std.c.environ);
    const environ = allocator.allocSentinel(?[*:0]const u8, environ_slice.len, null) catch unreachable;
    for (environ_slice, environ) |src, *dest| {
        if (src == null) {
            dest.* = null;
        } else {
            dest.* = (allocator.dupeZ(u8, sliceTo(src.?, 0)) catch unreachable).ptr;
        }
    }

    // we must clone selfExePath incase the argv[0] was not an absolute path (what appears in the terminal)
    const exec_path = (bun.selfExePath() catch unreachable).ptr;

    // we clone argv so that the memory address isn't the same as the libc one
    const newargv = @as([*:null]?[*:0]const u8, @ptrCast(dupe_argv.ptr));

    // we clone envp so that the memory address of environment variables isn't the same as the libc one
    const envp = @as([*:null]?[*:0]const u8, @ptrCast(environ.ptr));

    // macOS doesn't have CLOEXEC, so we must go through posix_spawn
    if (comptime Environment.isMac) {
        var actions = PosixSpawn.Actions.init() catch unreachable;
        actions.inherit(posix.STDIN_FD) catch unreachable;
        actions.inherit(posix.STDOUT_FD) catch unreachable;
        actions.inherit(posix.STDERR_FD) catch unreachable;

        var attrs = PosixSpawn.Attr.init() catch unreachable;
        attrs.resetSignals() catch {};

        attrs.set(
            C.translated.POSIX_SPAWN_CLOEXEC_DEFAULT |
                // Apple Extension: If this bit is set, rather
                // than returning to the caller, posix_spawn(2)
                // and posix_spawnp(2) will behave as a more
                // featureful execve(2).
                C.translated.POSIX_SPAWN_SETEXEC |
                C.translated.POSIX_SPAWN_SETSIGDEF | C.translated.POSIX_SPAWN_SETSIGMASK,
        ) catch unreachable;
        switch (PosixSpawn.spawnZ(exec_path, actions, attrs, @as([*:null]?[*:0]const u8, @ptrCast(newargv)), @as([*:null]?[*:0]const u8, @ptrCast(envp)))) {
            .err => |err| {
                if (may_return) {
                    Output.errGeneric("Failed to reload process: {s}", .{@tagName(err.getErrno())});
                    return;
                }
                Output.panic("Unexpected error while reloading: {d} {s}", .{ err.errno, @tagName(err.getErrno()) });
            },
            .result => |_| {
                if (may_return) {
                    Output.errGeneric("Failed to reload process", .{});
                    return;
                }
                Output.panic("Unexpected error while reloading: posix_spawn returned a result", .{});
            },
        }
    } else if (comptime Environment.isPosix) {
        on_before_reload_process_linux();
        const err = std.posix.execveZ(
            exec_path,
            newargv,
            envp,
        );
        if (may_return) {
            Output.errGeneric("Failed to reload process: {s}", .{@errorName(err)});
            return;
        }
        Output.panic("Unexpected error while reloading: {s}", .{@errorName(err)});
    } else {
        @compileError("unsupported platform for reloadProcess");
    }
}
pub var auto_reload_on_crash = false;

pub const options = @import("./options.zig");
pub const StringSet = struct {
    map: Map,

    pub const Map = StringArrayHashMap(void);

    pub fn clone(self: StringSet) !StringSet {
        var new_map = Map.init(self.map.allocator);
        try new_map.ensureTotalCapacity(self.map.count());
        for (self.map.keys()) |key| {
            new_map.putAssumeCapacity(try self.map.allocator.dupe(u8, key), {});
        }
        return StringSet{
            .map = new_map,
        };
    }

    pub fn init(allocator: std.mem.Allocator) StringSet {
        return StringSet{
            .map = Map.init(allocator),
        };
    }

    pub fn keys(self: StringSet) []const string {
        return self.map.keys();
    }

    pub fn insert(self: *StringSet, key: []const u8) !void {
        const entry = try self.map.getOrPut(key);
        if (!entry.found_existing) {
            entry.key_ptr.* = try self.map.allocator.dupe(u8, key);
        }
    }

    pub fn contains(self: *StringSet, key: []const u8) bool {
        return self.map.contains(key);
    }

    pub fn swapRemove(self: *StringSet, key: []const u8) bool {
        return self.map.swapRemove(key);
    }

    pub fn deinit(self: *StringSet) void {
        for (self.map.keys()) |key| {
            self.map.allocator.free(key);
        }

        self.map.deinit();
    }
};

pub const Schema = @import("./api/schema.zig");

pub const StringMap = struct {
    map: Map,
    dupe_keys: bool = false,

    pub const Map = StringArrayHashMap(string);

    pub fn clone(self: StringMap) !StringMap {
        return StringMap{
            .map = try self.map.clone(),
            .dupe_keys = self.dupe_keys,
        };
    }

    pub fn init(allocator: std.mem.Allocator, dupe_keys: bool) StringMap {
        return StringMap{
            .map = Map.init(allocator),
            .dupe_keys = dupe_keys,
        };
    }

    pub fn keys(self: StringMap) []const string {
        return self.map.keys();
    }

    pub fn values(self: StringMap) []const string {
        return self.map.values();
    }

    pub fn count(self: StringMap) usize {
        return self.map.count();
    }

    pub fn toAPI(self: StringMap) Schema.Api.StringMap {
        return Schema.Api.StringMap{
            .keys = self.keys(),
            .values = self.values(),
        };
    }

    pub fn insert(self: *StringMap, key: []const u8, value: []const u8) !void {
        const entry = try self.map.getOrPut(key);
        if (!entry.found_existing) {
            if (self.dupe_keys)
                entry.key_ptr.* = try self.map.allocator.dupe(u8, key);
        } else {
            self.map.allocator.free(entry.value_ptr.*);
        }

        entry.value_ptr.* = try self.map.allocator.dupe(u8, value);
    }
    pub const put = insert;

    pub fn get(self: *const StringMap, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }

    pub fn sort(self: *StringMap, sort_ctx: anytype) void {
        self.map.sort(sort_ctx);
    }

    pub fn deinit(self: *StringMap) void {
        for (self.map.values()) |value| {
            self.map.allocator.free(value);
        }

        if (self.dupe_keys) {
            for (self.map.keys()) |key| {
                self.map.allocator.free(key);
            }
        }

        self.map.deinit();
    }
};

pub const DotEnv = @import("./env_loader.zig");
pub const bundle_v2 = @import("./bundler/bundle_v2.zig");
pub const BundleV2 = bundle_v2.BundleV2;
pub const ParseTask = bundle_v2.ParseTask;

pub const Mutex = @import("./Mutex.zig");
pub const UnboundedQueue = @import("./bun.js/unbounded_queue.zig").UnboundedQueue;

pub fn threadlocalAllocator() std.mem.Allocator {
    if (comptime use_mimalloc) {
        return MimallocArena.getThreadlocalDefault();
    }

    return default_allocator;
}

pub fn HiveRef(comptime T: type, comptime capacity: u16) type {
    return struct {
        const HiveAllocator = HiveArray(@This(), capacity).Fallback;
        ref_count: u32,
        allocator: *HiveAllocator,
        value: T,

        pub fn init(value: T, allocator: *HiveAllocator) !*@This() {
            const this = try allocator.tryGet();
            this.* = .{
                .ref_count = 1,
                .allocator = allocator,
                .value = value,
            };
            return this;
        }

        pub fn ref(this: *@This()) *@This() {
            this.ref_count += 1;
            return this;
        }

        pub fn unref(this: *@This()) ?*@This() {
            const ref_count = this.ref_count;
            this.ref_count = ref_count - 1;
            if (ref_count == 1) {
                if (@hasDecl(T, "deinit")) {
                    this.value.deinit();
                }
                this.allocator.put(this);
                return null;
            }
            return this;
        }
    };
}

pub const MaxHeapAllocator = @import("./allocators/max_heap_allocator.zig").MaxHeapAllocator;

pub const tracy = @import("./tracy.zig");
pub const trace = tracy.trace;

pub fn openFileForPath(file_path: [:0]const u8) !std.fs.File {
    if (Environment.isWindows)
        return std.fs.cwd().openFileZ(file_path, .{});

    const O_PATH = if (comptime Environment.isLinux) O.PATH else O.RDONLY;
    const flags: u32 = O.CLOEXEC | O.NOCTTY | O_PATH;

    const fd = try std.posix.openZ(file_path, O.toPacked(flags), 0);
    return std.fs.File{
        .handle = fd,
    };
}

pub fn openDirForPath(file_path: [:0]const u8) !std.fs.Dir {
    if (Environment.isWindows)
        return std.fs.cwd().openDirZ(file_path, .{});

    const O_PATH = if (comptime Environment.isLinux) O.PATH else O.RDONLY;
    const flags: u32 = O.CLOEXEC | O.NOCTTY | O.DIRECTORY | O_PATH;

    const fd = try std.posix.openZ(file_path, O.toPacked(flags), 0);
    return std.fs.Dir{
        .fd = fd,
    };
}

pub const Generation = u16;

pub const zstd = @import("./deps/zstd.zig");
pub const StringPointer = Schema.Api.StringPointer;
pub const StandaloneModuleGraph = @import("./StandaloneModuleGraph.zig").StandaloneModuleGraph;

const _string = @import("./string.zig");
pub const strings = @import("string_immutable.zig");
pub const String = _string.String;
pub const StringJoiner = _string.StringJoiner;
pub const SliceWithUnderlyingString = _string.SliceWithUnderlyingString;
pub const PathString = _string.PathString;
pub const HashedString = _string.HashedString;
pub const MutableString = _string.MutableString;

pub const WTF = struct {
    /// The String type from WebKit's WTF library.
    pub const StringImpl = _string.WTFStringImpl;
};

pub const Wyhash11 = @import("./wyhash.zig").Wyhash11;

pub const RegularExpression = @import("./bun.js/bindings/RegularExpression.zig").RegularExpression;

const TODO_LOG = Output.scoped(.TODO, false);
pub inline fn todo(src: std.builtin.SourceLocation, value: anytype) @TypeOf(value) {
    if (comptime Environment.allow_assert) {
        TODO_LOG("{s}() at {s}:{d}:{d}", .{ src.fn_name, src.file, src.line, src.column });
    }

    return value;
}

/// Converts a native file descriptor into a `bun.FileDescriptor`
///
/// Accepts either a UV descriptor (i32) or a windows handle (*anyopaque)
pub fn toFD(fd: anytype) callconv(callconv_inline) FileDescriptor {
    const T = @TypeOf(fd);
    if (Environment.isWindows) {
        return (switch (T) {
            FDImpl => fd, // TODO: remove the toFD call from these places and make this a @compileError
            FDImpl.System => FDImpl.fromSystem(fd),
            FDImpl.UV, i32, comptime_int => FDImpl.fromUV(fd),
            FileDescriptor => FDImpl.decode(fd),
            std.fs.Dir => FDImpl.fromSystem(fd.fd),
            sys.File, std.fs.File => FDImpl.fromSystem(fd.handle),
            // TODO: remove u32
            u32 => FDImpl.fromUV(@intCast(fd)),
            else => @compileError("toFD() does not support type \"" ++ @typeName(T) ++ "\""),
        }).encode();
    } else {
        // TODO: remove intCast. we should not be casting u32 -> i32
        // even though file descriptors are always positive, linux/mac represents them as signed integers
        return switch (T) {
            FileDescriptor => fd, // TODO: remove the toFD call from these places and make this a @compileError
            sys.File => fd.handle,
            std.fs.File => @enumFromInt(fd.handle),
            std.fs.Dir => @enumFromInt(@as(i32, @intCast(fd.fd))),
            c_int, i32, u32, comptime_int => @enumFromInt(fd),
            else => @compileError("bun.toFD() not implemented for: " ++ @typeName(T)),
        };
    }
}

/// Converts a native file descriptor into a `bun.FileDescriptor`
///
/// Accepts either a UV descriptor (i32) or a windows handle (*anyopaque)
///
/// On windows, this file descriptor will always be backed by libuv, so calling .close() is safe.
pub inline fn toLibUVOwnedFD(fd: anytype) !FileDescriptor {
    const T = @TypeOf(fd);
    if (Environment.isWindows) {
        return (switch (T) {
            FDImpl.System => try FDImpl.fromSystem(fd).makeLibUVOwned(),
            FDImpl.UV => FDImpl.fromUV(fd),
            FileDescriptor => try FDImpl.decode(fd).makeLibUVOwned(),
            FDImpl => fd.makeLibUVOwned(),
            else => @compileError("toLibUVOwnedFD() does not support type \"" ++ @typeName(T) ++ "\""),
        }).encode();
    } else {
        return toFD(fd);
    }
}

/// Converts FileDescriptor into a UV file descriptor.
///
/// This explicitly is setup to disallow converting a Windows descriptor into a UV
/// descriptor. If this was allowed, then it would imply the caller still owns the
/// windows handle, but Win->UV will always invalidate the handle.
///
/// In that situation, it is almost impossible to close the handle properly,
/// you want to use `bun.FDImpl.decode(fd)` or `bun.toLibUVOwnedFD` instead.
///
/// This way, you can call .close() on the libuv descriptor.
pub inline fn uvfdcast(fd: anytype) FDImpl.UV {
    const T = @TypeOf(fd);
    if (Environment.isWindows) {
        const decoded = (switch (T) {
            FDImpl.System => @compileError("This cast (FDImpl.System -> FDImpl.UV) makes this file descriptor very hard to close. Use toLibUVOwnedFD() and FileDescriptor instead. If you truly need to do this conversion (Chloe will probably reject your PR), use bun.FDImpl.fromSystem(fd).uv()"),
            FDImpl => fd,
            FDImpl.UV => return fd,
            FileDescriptor => FDImpl.decode(fd),
            else => @compileError("uvfdcast() does not support type \"" ++ @typeName(T) ++ "\""),
        });

        // Specifically allow these anywhere:
        if (fd == win32.STDIN_FD) {
            return 0;
        }

        if (fd == win32.STDOUT_FD) {
            return 1;
        }

        if (fd == win32.STDERR_FD) {
            return 2;
        }

        if (Environment.allow_assert) {
            if (decoded.kind != .uv) {
                std.debug.panic("uvfdcast({}) called on an windows handle", .{decoded});
            }
        }
        return decoded.uv();
    } else {
        return fd.cast();
    }
}

pub inline fn socketcast(fd: anytype) std.posix.socket_t {
    if (Environment.isWindows) {
        return @ptrCast(FDImpl.decode(fd).system());
    } else {
        return fd.cast();
    }
}

pub const HOST_NAME_MAX = if (Environment.isWindows)
    // On Windows the maximum length, in bytes, of the string returned in the buffer pointed to by the name parameter is dependent on the namespace provider, but this string must be 256 bytes or less.
    // So if a buffer of 256 bytes is passed in the name parameter and the namelen parameter is set to 256, the buffer size will always be adequate.
    // https://learn.microsoft.com/en-us/windows/win32/api/winsock/nf-winsock-gethostname
    256
else
    std.posix.HOST_NAME_MAX;

const WindowsStat = extern struct {
    dev: u32,
    ino: u32,
    nlink: usize,

    mode: Mode,
    uid: u32,
    gid: u32,
    rdev: u32,
    size: u32,
    blksize: isize,
    blocks: i64,

    atim: std.c.timespec,
    mtim: std.c.timespec,
    ctim: std.c.timespec,

    pub fn birthtime(_: *const WindowsStat) std.c.timespec {
        return std.c.timespec{ .tv_nsec = 0, .tv_sec = 0 };
    }

    pub fn mtime(this: *const WindowsStat) std.c.timespec {
        return this.mtim;
    }

    pub fn ctime(this: *const WindowsStat) std.c.timespec {
        return this.ctim;
    }

    pub fn atime(this: *const WindowsStat) std.c.timespec {
        return this.atim;
    }
};

pub const Stat = if (Environment.isWindows) windows.libuv.uv_stat_t else std.posix.Stat;
pub const StatFS = switch (Environment.os) {
    .mac => C.translated.struct_statfs,
    .linux => C.translated.struct_statfs,
    else => windows.libuv.uv_statfs_t,
};

pub var argv: [][:0]const u8 = &[_][:0]const u8{};

pub fn initArgv(allocator: std.mem.Allocator) !void {
    if (comptime Environment.isPosix) {
        argv = try allocator.alloc([:0]const u8, std.os.argv.len);
        for (0..argv.len) |i| {
            argv[i] = std.mem.sliceTo(std.os.argv[i], 0);
        }
    } else if (comptime Environment.isWindows) {
        // Zig's implementation of `std.process.argsAlloc()`on Windows platforms
        // is not reliable, specifically the way it splits the command line string.
        //
        // For example, an arg like "foo\nbar" will be
        // erroneously split into two arguments: "foo" and "bar".
        //
        // To work around this, we can simply call the Windows API functions
        // that do this for us.
        //
        // Updates in Zig v0.12 related to Windows cmd line parsing may fix this,
        // see (here: https://ziglang.org/download/0.12.0/release-notes.html#Windows-Command-Line-Argument-Parsing),
        // so this may only need to be a temporary workaround.
        const cmdline_ptr = bun.windows.GetCommandLineW();
        var length: c_int = 0;

        // As per the documentation:
        // > The lifetime of the returned value is managed by the system,
        //   applications should not free or modify this value.
        const argvu16_ptr = windows.CommandLineToArgvW(cmdline_ptr, &length) orelse {
            switch (sys.getErrno({})) {
                // may be returned if can't alloc enough space for the str
                .NOMEM => return error.OutOfMemory,
                // may be returned if it's invalid
                .INVAL => return error.InvalidArgument,
                // TODO: anything else?
                else => return error.Unknown,
            }
        };

        const argvu16 = argvu16_ptr[0..@intCast(length)];
        const out_argv = try allocator.alloc([:0]const u8, @intCast(length));
        var string_builder = StringBuilder{};

        for (argvu16) |argraw| {
            const arg = std.mem.span(argraw);
            string_builder.count16Z(arg);
        }

        try string_builder.allocate(allocator);

        for (argvu16, out_argv) |argraw, *out| {
            const arg = std.mem.span(argraw);

            // Command line is expected to be valid UTF-16le
            // ...but sometimes, it's not valid. https://github.com/oven-sh/bun/issues/11610
            out.* = string_builder.append16(arg, default_allocator) orelse @panic("Failed to allocate memory for argv");
        }

        argv = out_argv;
    } else {
        argv = try std.process.argsAlloc(allocator);
    }
}

pub const posix = struct {
    pub const STDIN_FD = toFD(0);
    pub const STDOUT_FD = toFD(1);
    pub const STDERR_FD = toFD(2);

    pub fn stdio(i: anytype) FileDescriptor {
        return switch (i) {
            1 => STDOUT_FD,
            2 => STDERR_FD,
            0 => STDIN_FD,
            else => @panic("Invalid stdio fd"),
        };
    }

    pub const spawn = @import("./bun.js/api/bun/spawn.zig").PosixSpawn;
};

pub const win32 = struct {
    const w = std.os.windows;
    pub var STDOUT_FD: FileDescriptor = undefined;
    pub var STDERR_FD: FileDescriptor = undefined;
    pub var STDIN_FD: FileDescriptor = undefined;

    /// Returns the original mode, or null on failure
    pub fn updateStdioModeFlags(i: anytype, opts: struct { set: w.DWORD = 0, unset: w.DWORD = 0 }) !w.DWORD {
        const fd = stdio(i);
        var original_mode: w.DWORD = 0;
        if (windows.GetConsoleMode(fd.cast(), &original_mode) != 0) {
            if (windows.SetConsoleMode(fd.cast(), (original_mode | opts.set) & ~opts.unset) == 0) {
                return windows.getLastError();
            }
        } else return windows.getLastError();
        return original_mode;
    }

    const watcherChildEnv: [:0]const u16 = strings.toUTF16Literal("_BUN_WATCHER_CHILD");
    // magic exit code to indicate to the watcher manager that the child process should be re-spawned
    // this was randomly generated - we need to avoid using a common exit code that might be used by the script itself
    const watcher_reload_exit: w.DWORD = 3224497970;

    pub fn stdio(i: anytype) FileDescriptor {
        return switch (i) {
            0 => STDIN_FD,
            1 => STDOUT_FD,
            2 => STDERR_FD,
            else => @panic("Invalid stdio fd"),
        };
    }

    pub const spawn = @import("./bun.js/api/bun/spawn.zig").PosixSpawn;

    pub fn isWatcherChild() bool {
        var buf: [1]u16 = undefined;
        return windows.GetEnvironmentVariableW(@constCast(watcherChildEnv.ptr), &buf, 1) > 0;
    }

    pub fn becomeWatcherManager(allocator: std.mem.Allocator) noreturn {
        // this process will be the parent of the child process that actually runs the script
        var procinfo: std.os.windows.PROCESS_INFORMATION = undefined;
        C.windows_enable_stdio_inheritance();
        const job = windows.CreateJobObjectA(null, null) orelse Output.panic(
            "Could not create watcher Job Object: {s}",
            .{@tagName(std.os.windows.kernel32.GetLastError())},
        );
        var jeli = std.mem.zeroes(windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
        jeli.BasicLimitInformation.LimitFlags =
            windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE |
            windows.JOB_OBJECT_LIMIT_BREAKAWAY_OK |
            windows.JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK |
            windows.JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION;
        if (windows.SetInformationJobObject(
            job,
            windows.JobObjectExtendedLimitInformation,
            &jeli,
            @sizeOf(windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION),
        ) == 0) {
            Output.panic(
                "Could not configure watcher Job Object: {s}",
                .{@tagName(std.os.windows.kernel32.GetLastError())},
            );
        }

        while (true) {
            spawnWatcherChild(allocator, &procinfo, job) catch |err| {
                handleErrorReturnTrace(err, @errorReturnTrace());
                if (err == error.Win32Error) {
                    Output.panic("Failed to spawn process: {s}\n", .{@tagName(std.os.windows.kernel32.GetLastError())});
                }
                Output.panic("Failed to spawn process: {s}\n", .{@errorName(err)});
            };
            w.WaitForSingleObject(procinfo.hProcess, w.INFINITE) catch |err| {
                Output.panic("Failed to wait for child process: {s}\n", .{@errorName(err)});
            };
            var exit_code: w.DWORD = 0;
            if (w.kernel32.GetExitCodeProcess(procinfo.hProcess, &exit_code) == 0) {
                const err = windows.GetLastError();
                _ = std.os.windows.ntdll.NtClose(procinfo.hProcess);
                Output.panic("Failed to get exit code of child process: {s}\n", .{@tagName(err)});
            }
            _ = std.os.windows.ntdll.NtClose(procinfo.hProcess);

            // magic exit code to indicate that the child process should be re-spawned
            if (exit_code == watcher_reload_exit) {
                continue;
            } else {
                Global.exit(exit_code);
            }
        }
    }

    pub fn spawnWatcherChild(
        allocator: std.mem.Allocator,
        procinfo: *std.os.windows.PROCESS_INFORMATION,
        job: w.HANDLE,
    ) !void {
        // https://devblogs.microsoft.com/oldnewthing/20230209-00/?p=107812
        var attr_size: usize = undefined;
        _ = windows.InitializeProcThreadAttributeList(null, 1, 0, &attr_size);
        const p = try allocator.alloc(u8, attr_size);
        defer allocator.free(p);
        if (windows.InitializeProcThreadAttributeList(p.ptr, 1, 0, &attr_size) == 0) {
            return error.Win32Error;
        }
        if (windows.UpdateProcThreadAttribute(
            p.ptr,
            0,
            windows.PROC_THREAD_ATTRIBUTE_JOB_LIST,
            @ptrCast(&job),
            @sizeOf(w.HANDLE),
            null,
            null,
        ) == 0) {
            return error.Win32Error;
        }

        const flags: std.os.windows.DWORD = w.CREATE_UNICODE_ENVIRONMENT | windows.EXTENDED_STARTUPINFO_PRESENT;

        const image_path = windows.exePathW();
        var wbuf: WPathBuffer = undefined;
        @memcpy(wbuf[0..image_path.len], image_path);
        wbuf[image_path.len] = 0;

        const image_pathZ = wbuf[0..image_path.len :0];

        const kernelenv = w.kernel32.GetEnvironmentStringsW();
        defer {
            if (kernelenv) |envptr| {
                _ = w.kernel32.FreeEnvironmentStringsW(envptr);
            }
        }

        var size: usize = 0;
        if (kernelenv) |pointer| {
            // check that env is non-empty
            if (pointer[0] != 0 or pointer[1] != 0) {
                // array is terminated by two nulls
                while (pointer[size] != 0 or pointer[size + 1] != 0) size += 1;
                size += 1;
            }
        }
        // now pointer[size] is the first null

        const envbuf = try allocator.alloc(u16, size + watcherChildEnv.len + 4);
        defer allocator.free(envbuf);
        if (kernelenv) |pointer| {
            @memcpy(envbuf[0..size], pointer);
        }
        @memcpy(envbuf[size .. size + watcherChildEnv.len], watcherChildEnv);
        envbuf[size + watcherChildEnv.len] = '=';
        envbuf[size + watcherChildEnv.len + 1] = '1';
        envbuf[size + watcherChildEnv.len + 2] = 0;
        envbuf[size + watcherChildEnv.len + 3] = 0;

        var startupinfo = windows.STARTUPINFOEXW{
            .StartupInfo = .{
                .cb = @sizeOf(windows.STARTUPINFOEXW),
                .lpReserved = null,
                .lpDesktop = null,
                .lpTitle = null,
                .dwX = 0,
                .dwY = 0,
                .dwXSize = 0,
                .dwYSize = 0,
                .dwXCountChars = 0,
                .dwYCountChars = 0,
                .dwFillAttribute = 0,
                .dwFlags = w.STARTF_USESTDHANDLES,
                .wShowWindow = 0,
                .cbReserved2 = 0,
                .lpReserved2 = null,
                .hStdInput = std.io.getStdIn().handle,
                .hStdOutput = std.io.getStdOut().handle,
                .hStdError = std.io.getStdErr().handle,
            },
            .lpAttributeList = p.ptr,
        };
        @memset(std.mem.asBytes(procinfo), 0);
        const rc = w.kernel32.CreateProcessW(
            image_pathZ.ptr,
            bun.windows.GetCommandLineW(),
            null,
            null,
            1,
            flags,
            envbuf.ptr,
            null,
            @ptrCast(&startupinfo),
            procinfo,
        );
        if (rc == 0) {
            return error.Win32Error;
        }
        var is_in_job: w.BOOL = 0;
        _ = windows.IsProcessInJob(procinfo.hProcess, job, &is_in_job);
        assert(is_in_job != 0);
        _ = std.os.windows.ntdll.NtClose(procinfo.hThread);
    }
};

pub usingnamespace if (@import("builtin").target.os.tag != .windows) posix else win32;

pub fn isRegularFile(mode: anytype) bool {
    return S.ISREG(@intCast(mode));
}

pub const sys = @import("./sys.zig");
pub const O = sys.O;

pub const Mode = C.Mode;

pub const windows = @import("./windows.zig");

pub const FDTag = enum {
    none,
    stderr,
    stdin,
    stdout,
    pub fn get(fd_: anytype) FDTag {
        const fd = toFD(fd_);
        const T = @TypeOf(fd_);
        if (comptime Environment.isWindows) {
            if (@typeInfo(T) == .int or @typeInfo(T) == .comptime_int) {
                switch (fd_) {
                    0 => return .stdin,
                    1 => return .stdout,
                    2 => return .stderr,
                    else => {},
                }
            }

            if (fd == win32.STDOUT_FD) {
                return .stdout;
            } else if (fd == win32.STDERR_FD) {
                return .stderr;
            } else if (fd == win32.STDIN_FD) {
                return .stdin;
            }

            return .none;
        } else {
            return switch (fd) {
                posix.STDIN_FD => FDTag.stdin,
                posix.STDOUT_FD => FDTag.stdout,
                posix.STDERR_FD => FDTag.stderr,
                else => .none,
            };
        }
    }
};

pub fn fdi32(fd_: anytype) i32 {
    if (comptime Environment.isPosix) {
        return @intCast(toFD(fd_));
    }

    if (comptime @TypeOf(fd_) == *anyopaque) {
        return @intCast(@intFromPtr(fd_));
    }

    return @intCast(fd_);
}

pub const LazyBoolValue = enum {
    unknown,
    no,
    yes,
};
/// Create a lazily computed boolean value.
/// Getter must be a function that takes a pointer to the parent struct and returns a boolean.
/// Parent must be a type which contains the field we are getting.
pub fn LazyBool(comptime Getter: anytype, comptime Parent: type, comptime field: string) type {
    return struct {
        value: LazyBoolValue = .unknown,

        pub fn get(self: *@This()) bool {
            if (self.value == .unknown) {
                const parent: *Parent = @alignCast(@fieldParentPtr(field, self));
                self.value = switch (Getter(parent)) {
                    true => .yes,
                    false => .no,
                };
            }

            return self.value == .yes;
        }
    };
}

pub fn serializable(input: anytype) @TypeOf(input) {
    const T = @TypeOf(input);
    comptime {
        if (trait.isExternContainer(T)) {
            if (@typeInfo(T) == .@"union") {
                @compileError("Extern unions must be serialized with serializableInto");
            }
        }
    }
    var zeroed: [@sizeOf(T)]u8 align(@alignOf(T)) = std.mem.zeroes([@sizeOf(T)]u8);
    const result: *T = @ptrCast(&zeroed);

    inline for (comptime std.meta.fieldNames(T)) |field_name| {
        @field(result, field_name) = @field(input, field_name);
    }

    return result.*;
}

pub inline fn serializableInto(comptime T: type, init: anytype) T {
    var zeroed: [@sizeOf(T)]u8 align(@alignOf(T)) = std.mem.zeroes([@sizeOf(T)]u8);
    const result: *T = @ptrCast(&zeroed);

    inline for (comptime std.meta.fieldNames(@TypeOf(init))) |field_name| {
        @field(result, field_name) = @field(init, field_name);
    }

    return result.*;
}

/// Like std.fs.Dir.makePath except instead of infinite looping on dangling
/// symlink, it deletes the symlink and tries again.
pub fn makePath(dir: std.fs.Dir, sub_path: []const u8) !void {
    var it = try std.fs.path.componentIterator(sub_path);
    var component = it.last() orelse return;
    while (true) {
        dir.makeDir(component.path) catch |err| switch (err) {
            error.PathAlreadyExists => {
                var path_buf2: [MAX_PATH_BYTES * 2]u8 = undefined;
                copy(u8, &path_buf2, component.path);

                path_buf2[component.path.len] = 0;
                const path_to_use = path_buf2[0..component.path.len :0];
                const result = try sys.lstat(path_to_use).unwrap();
                const is_dir = S.ISDIR(@intCast(result.mode));
                // dangling symlink
                if (!is_dir) {
                    dir.deleteTree(component.path) catch {};
                    continue;
                }
            },
            error.FileNotFound => |e| {
                component = it.previous() orelse return e;
                continue;
            },
            else => |e| return e,
        };
        component = it.next() orelse return;
    }
}

/// Like std.fs.Dir.makePath except instead of infinite looping on dangling
/// symlink, it deletes the symlink and tries again.
pub fn makePathW(dir: std.fs.Dir, sub_path: []const u16) !void {
    // was going to copy/paste makePath and use all W versions but they didn't all exist
    // and this buffer was needed anyway
    var buf: PathBuffer = undefined;
    const buf_len = simdutf.convert.utf16.to.utf8.le(sub_path, &buf);
    return makePath(dir, buf[0..buf_len]);
}

pub const Async = @import("async");

/// This is a helper for writing path string literals that are compatible with Windows.
/// Returns the string as-is on linux, on windows replace `/` with `\`
pub inline fn pathLiteral(comptime literal: anytype) *const [literal.len:0]u8 {
    if (!Environment.isWindows) return @ptrCast(literal);
    return comptime {
        var buf: [literal.len:0]u8 = undefined;
        for (literal, 0..) |char, i| {
            buf[i] = if (char == '/') '\\' else char;
            assert(buf[i] != 0 and buf[i] < 128);
        }
        buf[buf.len] = 0;
        const final = buf[0..buf.len :0].*;
        return &final;
    };
}

/// Same as `pathLiteral`, but the character type is chosen from platform.
pub inline fn OSPathLiteral(comptime literal: anytype) *const [literal.len:0]OSPathChar {
    if (!Environment.isWindows) return @ptrCast(literal);
    return comptime {
        var buf: [literal.len:0]OSPathChar = undefined;
        for (literal, 0..) |char, i| {
            buf[i] = if (char == '/') '\\' else char;
            assert(buf[i] != 0 and buf[i] < 128);
        }
        buf[buf.len] = 0;
        const final = buf[0..buf.len :0].*;
        return &final;
    };
}

pub const MakePath = struct {
    const w = std.os.windows;

    // TODO(@paperclover): upstream making this public into zig std
    // there is zero reason this must be copied
    //
    /// Calls makeOpenDirAccessMaskW iteratively to make an entire path
    /// (i.e. creating any parent directories that do not exist).
    /// Opens the dir if the path already exists and is a directory.
    /// This function is not atomic, and if it returns an error, the file system may
    /// have been modified regardless.
    fn makeOpenPathAccessMaskW(self: std.fs.Dir, comptime T: type, sub_path: []const T, access_mask: u32, no_follow: bool) !std.fs.Dir {
        const Iterator = std.fs.path.ComponentIterator(.windows, T);
        var it = try Iterator.init(sub_path);
        // If there are no components in the path, then create a dummy component with the full path.
        var component = it.last() orelse Iterator.Component{
            .name = &.{},
            .path = sub_path,
        };

        while (true) {
            const sub_path_w = if (comptime T == u16)
                try w.wToPrefixedFileW(self.fd,
                    // TODO: report this bug
                    // they always copy it
                    // it doesn't need to be [:0]const u16
                    @ptrCast(component.path))
            else
                try w.sliceToPrefixedFileW(self.fd, component.path);
            var result = makeOpenDirAccessMaskW(self, sub_path_w.span().ptr, access_mask, .{
                .no_follow = no_follow,
                .create_disposition = w.FILE_OPEN_IF,
            }) catch |err| switch (err) {
                error.FileNotFound => |e| {
                    component = it.previous() orelse return e;
                    continue;
                },
                else => |e| return e,
            };

            component = it.next() orelse return result;
            // Don't leak the intermediate file handles
            result.close();
        }
    }
    const MakeOpenDirAccessMaskWOptions = struct {
        no_follow: bool,
        create_disposition: u32,
    };

    fn makeOpenDirAccessMaskW(self: std.fs.Dir, sub_path_w: [*:0]const u16, access_mask: u32, flags: MakeOpenDirAccessMaskWOptions) !std.fs.Dir {
        var result = std.fs.Dir{
            .fd = undefined,
        };

        const path_len_bytes = @as(u16, @intCast(std.mem.sliceTo(sub_path_w, 0).len * 2));
        var nt_name = w.UNICODE_STRING{
            .Length = path_len_bytes,
            .MaximumLength = path_len_bytes,
            .Buffer = @constCast(sub_path_w),
        };
        var attr = w.OBJECT_ATTRIBUTES{
            .Length = @sizeOf(w.OBJECT_ATTRIBUTES),
            .RootDirectory = if (std.fs.path.isAbsoluteWindowsW(sub_path_w)) null else self.fd,
            .Attributes = 0, // Note we do not use OBJ_CASE_INSENSITIVE here.
            .ObjectName = &nt_name,
            .SecurityDescriptor = null,
            .SecurityQualityOfService = null,
        };
        const open_reparse_point: w.DWORD = if (flags.no_follow) w.FILE_OPEN_REPARSE_POINT else 0x0;
        var status: w.IO_STATUS_BLOCK = undefined;
        const rc = w.ntdll.NtCreateFile(
            &result.fd,
            access_mask,
            &attr,
            &status,
            null,
            w.FILE_ATTRIBUTE_NORMAL,
            w.FILE_SHARE_READ | w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE,
            flags.create_disposition,
            w.FILE_DIRECTORY_FILE | w.FILE_SYNCHRONOUS_IO_NONALERT | w.FILE_OPEN_FOR_BACKUP_INTENT | w.FILE_WRITE_THROUGH | open_reparse_point,
            null,
            0,
        );

        switch (rc) {
            .SUCCESS => return result,
            .OBJECT_NAME_INVALID => return error.BadPathName,
            .OBJECT_NAME_NOT_FOUND => return error.FileNotFound,
            .OBJECT_PATH_NOT_FOUND => return error.FileNotFound,
            .NOT_A_DIRECTORY => return error.NotDir,
            // This can happen if the directory has 'List folder contents' permission set to 'Deny'
            // and the directory is trying to be opened for iteration.
            .ACCESS_DENIED => return error.AccessDenied,
            .INVALID_PARAMETER => return error.BadPathName,
            .SHARING_VIOLATION => return error.SharingViolation,
            else => return w.unexpectedStatus(rc),
        }
    }

    pub fn makeOpenPath(self: std.fs.Dir, sub_path: anytype, opts: std.fs.Dir.OpenDirOptions) !std.fs.Dir {
        if (comptime Environment.isWindows) {
            return makeOpenPathAccessMaskW(
                self,
                std.meta.Elem(@TypeOf(sub_path)),
                sub_path,
                w.STANDARD_RIGHTS_READ |
                    w.FILE_READ_ATTRIBUTES |
                    w.FILE_READ_EA |
                    w.SYNCHRONIZE |
                    w.FILE_TRAVERSE,
                false,
            );
        }

        return self.makeOpenPath(sub_path, opts);
    }

    /// copy/paste of `std.fs.Dir.makePath` and related functions and modified to support u16 slices.
    /// inside `MakePath` scope to make deleting later easier.
    /// TODO(dylan-conway) delete `MakePath`
    pub fn makePath(comptime T: type, self: std.fs.Dir, sub_path: []const T) !void {
        if (Environment.isWindows) {
            var dir = try makeOpenPath(self, sub_path, .{});
            dir.close();
            return;
        }

        var it = try componentIterator(T, sub_path);
        var component = it.last() orelse return;
        while (true) {
            std.fs.Dir.makeDir(self, component.path) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    // TODO stat the file and return an error if it's not a directory
                    // this is important because otherwise a dangling symlink
                    // could cause an infinite loop
                },
                error.FileNotFound => |e| {
                    component = it.previous() orelse return e;
                    continue;
                },
                else => |e| return e,
            };
            component = it.next() orelse return;
        }
    }

    fn componentIterator(comptime T: type, path_: []const T) !std.fs.path.ComponentIterator(switch (builtin.target.os.tag) {
        .windows => .windows,
        .uefi => .uefi,
        else => .posix,
    }, T) {
        return std.fs.path.ComponentIterator(switch (builtin.target.os.tag) {
            .windows => .windows,
            .uefi => .uefi,
            else => .posix,
        }, T).init(path_);
    }
};

pub const Dirname = struct {
    /// copy/paste of `std.fs.path.dirname` and related functions and modified to support u16 slices.
    /// inside `Dirname` scope to make deleting later easier.
    /// TODO(dylan-conway) delete `Dirname`
    pub fn dirname(comptime T: type, path_: []const T) ?[]const T {
        if (builtin.target.os.tag == .windows) {
            return dirnameWindows(T, path_);
        } else {
            return std.fs.path.dirnamePosix(path_);
        }
    }

    fn dirnameWindows(comptime T: type, path_: []const T) ?[]const T {
        if (path_.len == 0)
            return null;

        const root_slice = diskDesignatorWindows(T, path_);
        if (path_.len == root_slice.len)
            return null;

        const have_root_slash = path_.len > root_slice.len and (path_[root_slice.len] == '/' or path_[root_slice.len] == '\\');

        var end_index: usize = path_.len - 1;

        while (path_[end_index] == '/' or path_[end_index] == '\\') {
            if (end_index == 0)
                return null;
            end_index -= 1;
        }

        while (path_[end_index] != '/' and path_[end_index] != '\\') {
            if (end_index == 0)
                return null;
            end_index -= 1;
        }

        if (have_root_slash and end_index == root_slice.len) {
            end_index += 1;
        }

        if (end_index == 0)
            return null;

        return path_[0..end_index];
    }

    fn diskDesignatorWindows(comptime T: type, path_: []const T) []const T {
        return windowsParsePath(T, path_).disk_designator;
    }

    fn windowsParsePath(comptime T: type, path_: []const T) WindowsPath(T) {
        const WindowsPath_ = WindowsPath(T);
        if (path_.len >= 2 and path_[1] == ':') {
            return WindowsPath_{
                .is_abs = if (comptime T == u16) std.fs.path.isAbsoluteWindowsWTF16(path_) else std.fs.path.isAbsolute(path_),
                .kind = WindowsPath_.Kind.Drive,
                .disk_designator = path_[0..2],
            };
        }
        if (path_.len >= 1 and (path_[0] == '/' or path_[0] == '\\') and
            (path_.len == 1 or (path_[1] != '/' and path_[1] != '\\')))
        {
            return WindowsPath_{
                .is_abs = true,
                .kind = WindowsPath_.Kind.None,
                .disk_designator = path_[0..0],
            };
        }
        const relative_path = WindowsPath_{
            .kind = WindowsPath_.Kind.None,
            .disk_designator = &[_]T{},
            .is_abs = false,
        };
        if (path_.len < "//a/b".len) {
            return relative_path;
        }

        inline for ("/\\") |this_sep| {
            const two_sep = [_]T{ this_sep, this_sep };
            if (std.mem.startsWith(T, path_, &two_sep)) {
                if (path_[2] == this_sep) {
                    return relative_path;
                }

                var it = std.mem.tokenizeScalar(T, path_, this_sep);
                _ = (it.next() orelse return relative_path);
                _ = (it.next() orelse return relative_path);
                return WindowsPath_{
                    .is_abs = if (T == u16) std.fs.path.isAbsoluteWindowsWTF16(path_) else std.fs.path.isAbsolute(path_),
                    .kind = WindowsPath_.Kind.NetworkShare,
                    .disk_designator = path_[0..it.index],
                };
            }
        }
        return relative_path;
    }

    fn WindowsPath(comptime T: type) type {
        return struct {
            is_abs: bool,
            kind: Kind,
            disk_designator: []const T,

            pub const Kind = enum {
                None,
                Drive,
                NetworkShare,
            };
        };
    }
};

pub noinline fn outOfMemory() noreturn {
    @branchHint(.cold);
    crash_handler.crashHandler(.out_of_memory, null, @returnAddress());
}

pub fn todoPanic(src: std.builtin.SourceLocation, comptime format: string, args: anytype) noreturn {
    @branchHint(.cold);
    bun.Analytics.Features.todo_panic = 1;
    Output.panic("TODO: " ++ format ++ " ({s}:{d})", args ++ .{ src.file, src.line });
}

/// Wrapper around allocator.create(T) that safely initializes the pointer. Prefer this over
/// `std.mem.Allocator.create`, but prefer using `bun.new` over `create(default_allocator, T, t)`
pub fn create(allocator: std.mem.Allocator, comptime T: type, t: T) *T {
    const pointer = allocator.create(T) catch outOfMemory();
    pointer.* = t;
    return pointer;
}

pub const heap_breakdown = @import("./heap_breakdown.zig");

/// Globally-allocate a value on the heap. Must free with `bun.destroy`.
/// Prefer this over `default_allocator.create`
///
/// By using this over the default allocator, you gain access to:
/// - Automatic named heaps on macOS.
/// - Additional assertions when freeing memory.
///
/// On macOS, you can use `Bun.unsafe.mimallocDump()` to dump the heap.
pub inline fn new(comptime T: type, init: T) *T {
    const pointer = if (heap_breakdown.enabled)
        heap_breakdown.getZoneT(T).create(T, init)
    else pointer: {
        const pointer = default_allocator.create(T) catch outOfMemory();
        pointer.* = init;
        break :pointer pointer;
    };

    // TODO::
    // if (comptime Environment.allow_assert) {
    //     const logAlloc = Output.scoped(.alloc, @hasDecl(T, "logAllocations"));
    //     logAlloc("new({s}) = {*}", .{ meta.typeName(T), ptr });
    // }

    return pointer;
}

/// Free a globally-allocated a value from `bun.new()`.
/// For single-item heap pointers, prefer bun.new/destroy over default_allocator
///
/// Destruction performs additional safety checks:
/// - Generic assertions can be added to T.assertMayDeinit()
/// - Automatic integration with `RefCount`
pub inline fn destroy(pointer: anytype) void {
    const T = std.meta.Child(@TypeOf(pointer));

    if (Environment.allow_assert) {
        const logAlloc = Output.scoped(.alloc, @hasDecl(T, "logAllocations"));
        logAlloc("destroy({s}) = {*}", .{ meta.typeName(T), pointer });

        // If this type implements a RefCount, make sure it is zero.
        @import("./ptr/ref_count.zig").maybeAssertNoRefs(T, pointer);

        switch (@typeInfo(T)) {
            .@"struct", .@"union", .@"enum" => if (@hasDecl(T, "assertMayDeinit"))
                pointer.assertMayDeinit(),
            else => {},
        }
    }

    if (comptime heap_breakdown.enabled) {
        heap_breakdown.getZoneT(T).destroy(T, pointer);
    } else {
        default_allocator.destroy(pointer);
    }
}

pub inline fn dupe(comptime T: type, t: *T) *T {
    return new(T, t.*);
}

/// Implements `fn new` for a type.
/// Pair with `TrivialDeinit` if the type contains no pointers.
pub fn TrivialNew(comptime T: type) fn (T) *T {
    return struct {
        pub fn new(t: T) *T {
            return bun.new(T, t);
        }
    }.new;
}

/// Implements `fn deinit` for a type.
/// Pair with `TrivialNew` if the type contains no pointers.
pub fn TrivialDeinit(comptime T: type) fn (*T) void {
    return struct {
        pub fn deinit(self: *T) void {
            // TODO: assert that the structure contains no pointers.
            //
            // // Assert the structure contains no pointers. If there are
            // // pointers, you must implement `deinit` manually, ideally
            // // explaining why those pointers should or should not be freed.
            // const fields = switch (@typeInfo(T)) {
            //     .@"struct", .@"union" => |i| i.fields,
            //     else => @compileError("please implement `deinit` manually"),
            // };

            bun.destroy(self);
        }
    }.deinit;
}

pub fn exitThread() noreturn {
    const exiter = struct {
        pub extern "c" fn pthread_exit(?*anyopaque) noreturn;
        pub extern "kernel32" fn ExitThread(windows.DWORD) noreturn;
    };

    if (comptime Environment.isWindows) {
        exiter.ExitThread(0);
    } else if (comptime Environment.isPosix) {
        exiter.pthread_exit(null);
    } else {
        @compileError("Unsupported platform");
    }
}

pub fn deleteAllPoolsForThreadExit() void {
    const pools_to_delete = .{
        JSC.WebCore.ByteListPool,
        bun.WPathBufferPool,
        bun.PathBufferPool,
        bun.JSC.ConsoleObject.Formatter.Visited.Pool,
        bun.js_parser.StringVoidMap.Pool,
    };
    inline for (pools_to_delete) |pool| {
        pool.deleteAll();
    }
}

pub const Tmpfile = @import("./tmp.zig").Tmpfile;

pub const io = @import("./io/io.zig");

const errno_map = errno_map: {
    var max_value = 0;
    for (std.enums.values(C.SystemErrno)) |v|
        max_value = @max(max_value, @intFromEnum(v));

    var map: [max_value + 1]anyerror = undefined;
    @memset(&map, error.Unexpected);
    for (std.enums.values(C.SystemErrno)) |v|
        map[@intFromEnum(v)] = @field(anyerror, @tagName(v));

    break :errno_map map;
};

pub fn errnoToZigErr(err: anytype) anyerror {
    var num = if (@typeInfo(@TypeOf(err)) == .@"enum")
        @intFromEnum(err)
    else
        err;

    if (Environment.allow_assert) {
        assert(num != 0);
    }

    if (Environment.os == .windows) {
        // uv errors are negative, normalizing it will make this more resilient
        num = @abs(num);
    } else {
        if (Environment.allow_assert) {
            assert(num > 0);
        }
    }

    if (num > 0 and num < errno_map.len)
        return errno_map[num];

    return error.Unexpected;
}

pub const S = if (Environment.isWindows) C.S else std.posix.S;

pub const brotli = @import("./brotli.zig");

pub fn iterateDir(dir: std.fs.Dir) DirIterator.Iterator {
    return DirIterator.iterate(dir, .u8).iter;
}

fn ReinterpretSliceType(comptime T: type, comptime slice: type) type {
    const is_const = @typeInfo(slice).pointer.is_const;
    return if (is_const) []const T else []T;
}

/// Zig has a todo for @ptrCast changing the `.len`. This is the workaround
pub fn reinterpretSlice(comptime T: type, slice: anytype) ReinterpretSliceType(T, @TypeOf(slice)) {
    const is_const = @typeInfo(@TypeOf(slice)).pointer.is_const;
    const bytes = std.mem.sliceAsBytes(slice);
    const new_ptr = @as(if (is_const) [*]const T else [*]T, @ptrCast(@alignCast(bytes.ptr)));
    return new_ptr[0..@divTrunc(bytes.len, @sizeOf(T))];
}

extern "kernel32" fn GetUserNameA(username: *u8, size: *u32) callconv(std.os.windows.WINAPI) c_int;

pub fn getUserName(output_buffer: []u8) ?[]const u8 {
    if (Environment.isWindows) {
        var size: u32 = @intCast(output_buffer.len);
        if (GetUserNameA(@ptrCast(@constCast(output_buffer.ptr)), &size) == 0) {
            return null;
        }
        return output_buffer[0..size];
    }
    var env = std.process.getEnvMap(default_allocator) catch outOfMemory();
    const user = env.get("USER") orelse return null;
    const size = @min(output_buffer.len, user.len);
    copy(u8, output_buffer[0..size], user[0..size]);
    return output_buffer[0..size];
}

pub inline fn resolveSourcePath(
    comptime root: enum { codegen, src },
    comptime sub_path: string,
) string {
    return comptime path: {
        @setEvalBranchQuota(2000000);
        var buf: bun.PathBuffer = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const resolved = (std.fs.path.resolve(fba.allocator(), &.{
            switch (root) {
                .codegen => Environment.codegen_path,
                .src => Environment.base_path ++ "/src",
            },
            sub_path,
        }) catch
            @compileError(unreachable))[0..].*;
        break :path &resolved;
    };
}

const RuntimeEmbedRoot = enum {
    /// Relative to `<build>/codegen`.
    codegen,
    /// Relative to `src`
    src,
    /// Reallocates the slice at every call. Avoid this if possible.  An example
    /// using this reasonably is referencing incremental_visualizer.html, which
    /// is reloaded from disk for each request, but more importantly allows
    /// maintaining the DevServer state while hacking on the visualizer.
    src_eager,
    /// Avoid this if possible. See `.src_eager`.
    codegen_eager,
};

/// Load a file at runtime. This is only to be used in debug builds,
/// specifically when `Environment.codegen_embed` is false. This allows quick
/// iteration on files, as this skips the Zig compiler. Once Zig gains good
/// incremental support, the non-eager cases can be deleted.
pub fn runtimeEmbedFile(
    comptime root: RuntimeEmbedRoot,
    comptime sub_path: []const u8,
) [:0]const u8 {
    comptime assert(Environment.isDebug);
    comptime assert(!Environment.codegen_embed);

    const abs_path = switch (root) {
        .codegen, .codegen_eager => resolveSourcePath(.codegen, sub_path),
        .src, .src_eager => resolveSourcePath(.src, sub_path),
    };

    const static = struct {
        var once = bun.once(load);

        fn load() [:0]const u8 {
            return std.fs.cwd().readFileAllocOptions(
                default_allocator,
                abs_path,
                std.math.maxInt(usize),
                null,
                @alignOf(u8),
                '\x00',
            ) catch |e| {
                Output.panic(
                    \\Failed to load '{s}': {}
                    \\
                    \\To improve iteration speed, some files are not embedded but
                    \\loaded at runtime, at the cost of making the binary non-portable.
                    \\To fix this, pass -DCODEGEN_EMBED=ON to CMake
                , .{ abs_path, e });
            };
        }
    };

    if ((root == .src_eager or root == .codegen_eager) and static.once.done) {
        static.once.done = false;
        default_allocator.free(static.once.payload);
    }

    return static.once.call(.{});
}

pub inline fn markWindowsOnly() if (Environment.isWindows) void else noreturn {
    if (Environment.isWindows) {
        return;
    }

    if (@inComptime()) {
        @compileError("This function is only available on Windows");
    }

    @panic("Assertion failure: this function should only be accessible on Windows.");
}

pub inline fn markPosixOnly() if (Environment.isPosix) void else noreturn {
    if (Environment.isPosix) {
        return;
    }

    if (@inComptime()) {
        @compileError("This function is only available on POSIX");
    }

    @panic("Assertion failure: this function should only be accessible on POSIX.");
}

pub fn linuxKernelVersion() Semver.Version {
    if (comptime !Environment.isLinux) @compileError("linuxKernelVersion() is only available on Linux");
    return analytics.GenerateHeader.GeneratePlatform.kernelVersion();
}

pub fn selfExePath() ![:0]u8 {
    const memo = struct {
        var set = false;
        // TODO open zig issue to make 'std.fs.selfExePath' return [:0]u8 directly
        // note: this doesn't use MAX_PATH_BYTES because on windows that's 32767*3+1 yet normal paths are 255.
        // should this fail it will still do so gracefully. 4096 is MAX_PATH_BYTES on posix.
        var value: [
            4096 + 1 // + 1 for the null terminator
        ]u8 = undefined;
        var len: usize = 0;
        var lock: Mutex = .{};

        pub fn load() ![:0]u8 {
            const init = try std.fs.selfExePath(&value);
            @This().len = init.len;
            value[@This().len] = 0;
            set = true;
            return value[0..@This().len :0];
        }
    };

    // try without a lock
    if (memo.set) return memo.value[0..memo.len :0];

    // make it thread-safe
    memo.lock.lock();
    defer memo.lock.unlock();
    // two calls could happen concurrently, so we must check again
    if (memo.set) return memo.value[0..memo.len :0];
    return memo.load();
}
pub const exe_suffix = if (Environment.isWindows) ".exe" else "";

pub const spawnSync = @This().spawn.sync.spawn;

pub fn SliceIterator(comptime T: type) type {
    return struct {
        items: []const T,
        index: usize = 0,

        pub fn init(items: []const T) @This() {
            return .{ .items = items };
        }

        pub fn next(this: *@This()) ?T {
            if (this.index >= this.items.len) return null;
            defer this.index += 1;
            return this.items[this.index];
        }
    };
}

pub const Futex = @import("./futex.zig");

// TODO: migrate
pub const ArenaAllocator = std.heap.ArenaAllocator;

pub const crash_handler = @import("crash_handler.zig");
pub const handleErrorReturnTrace = crash_handler.handleErrorReturnTrace;

const assertion_failure_msg = "Internal assertion failure";
noinline fn assertionFailure() noreturn {
    if (@inComptime()) {
        @compileError("assertion failure");
    } else {
        @branchHint(.cold);
        Output.panic(assertion_failure_msg, .{});
    }
}

noinline fn assertionFailureAtLocation(src: std.builtin.SourceLocation) noreturn {
    if (@inComptime()) {
        @compileError(std.fmt.comptimePrint("assertion failure"));
    } else {
        @branchHint(.cold);
        Output.panic(assertion_failure_msg ++ "at {s}:{d}:{d}", .{ src.file, src.line, src.column });
    }
}

noinline fn assertionFailureWithMsg(comptime msg: []const u8, args: anytype) noreturn {
    if (@inComptime()) {
        @compileError(std.fmt.comptimePrint("assertion failure: " ++ msg, args));
    } else {
        @branchHint(.cold);
        Output.panic(assertion_failure_msg ++ ": " ++ msg, args);
    }
}

/// Like `assert`, but checks only run in debug builds.
///
/// Please wrap expensive checks in an `if` statement.
/// ```zig
/// if (comptime bun.Environment.isDebug) {
///   const expensive = doExpensiveCheck();
///   bun.debugAssert(expensive);
/// }
/// ```
pub fn debugAssert(cheap_value_only_plz: bool) callconv(callconv_inline) void {
    if (comptime !Environment.isDebug) {
        return;
    }

    if (!cheap_value_only_plz) {
        unreachable;
    }
}

/// Asserts that some condition holds. Assertions are stripped in release builds.
///
/// Please use `assertf` in new code.
///
/// Be careful what expressions you pass to this function; if the compiler cannot
/// determine that `ok` has no side effects, the argument expression may not be removed
/// from the binary. This includes calls to extern functions.
///
/// Wrap expensive checks in an `if` statement.
/// ```zig
/// if (comptime bun.Environment.allow_assert) {
///   const expensive = doExpensiveCheck();
///   bun.assert(expensive);
/// }
/// ```
///
/// Use `releaseAssert` for assertions that should not be stripped in release builds.
pub fn assert(ok: bool) callconv(callconv_inline) void {
    if (comptime !Environment.allow_assert) {
        return;
    }

    if (!ok) {
        if (comptime Environment.isDebug) unreachable;
        assertionFailure();
    }
}

/// Asserts that some condition holds. Assertions are stripped in release builds.
///
/// Please note that messages will be shown to users in crash reports.
///
/// Be careful what expressions you pass to this function; if the compiler cannot
/// determine that `ok` has no side effects, the argument expression may not be removed
/// from the binary. This includes calls to extern functions.
///
/// Wrap expensive checks in an `if` statement.
/// ```zig
/// if (comptime bun.Environment.allow_assert) {
///   const expensive = doExpensiveCheck();
///   bun.assert(expensive, "Something happened: {}", .{ expensive });
/// }
/// ```
///
/// Use `releaseAssert` for assertions that should not be stripped in release builds.
pub fn assertf(ok: bool, comptime format: []const u8, args: anytype) callconv(callconv_inline) void {
    if (comptime !Environment.allow_assert) {
        return;
    }

    if (!ok) {
        // crash handler has runtime-only code.
        if (@inComptime()) @compileError(std.fmt.comptimePrint(format, args));
        assertionFailureWithMsg(format, args);
    }
}

/// Asserts that some condition holds. These assertions are not stripped
/// in any build mode. Use `assert` to have assertions stripped in release
/// builds.
pub fn releaseAssert(ok: bool, comptime msg: []const u8, args: anytype) callconv(callconv_inline) void {
    if (!ok) {
        @branchHint(.cold);
        Output.panic(assertion_failure_msg ++ ": " ++ msg, args);
    }
}

pub fn assertWithLocation(value: bool, src: std.builtin.SourceLocation) callconv(callconv_inline) void {
    if (comptime !Environment.allow_assert) {
        return;
    }

    if (!value) {
        if (comptime Environment.isDebug) unreachable;
        assertionFailureAtLocation(src);
    }
}

/// This has no effect on the real code but capturing 'a' and 'b' into
/// parameters makes assertion failures much easier inspect in a debugger.
pub inline fn assert_eql(a: anytype, b: anytype) void {
    if (@inComptime()) {
        if (a != b) {
            @compileLog(a);
            @compileLog(b);
            @compileError("A != B");
        }
    }
    if (!Environment.allow_assert) return;
    if (a != b) {
        Output.panic("Assertion failure: {any} != {any}", .{ a, b });
    }
}

/// This has no effect on the real code but capturing 'a' and 'b' into
/// parameters makes assertion failures much easier inspect in a debugger.
pub fn assert_neql(a: anytype, b: anytype) callconv(callconv_inline) void {
    return assert(a != b);
}

pub fn unsafeAssert(condition: bool) callconv(callconv_inline) void {
    if (!condition) unreachable;
}

pub const dns = @import("./dns.zig");

pub fn getRoughTickCount() timespec {
    if (comptime Environment.isMac) {
        // https://opensource.apple.com/source/xnu/xnu-2782.30.5/libsyscall/wrappers/mach_approximate_time.c.auto.html
        // https://opensource.apple.com/source/Libc/Libc-1158.1.2/gen/clock_gettime.c.auto.html
        var spec = timespec{
            .nsec = 0,
            .sec = 0,
        };
        const clocky = struct {
            pub var clock_id: std.c.CLOCK = .REALTIME;
            pub fn get() void {
                var res = timespec{};
                _ = std.c.clock_getres(.MONOTONIC_RAW_APPROX, @ptrCast(&res));
                if (res.ms() <= 1) {
                    clock_id = .MONOTONIC_RAW_APPROX;
                } else {
                    clock_id = .MONOTONIC_RAW;
                }
            }

            pub var once = std.once(get);
        };
        clocky.once.call();

        // We use this one because we can avoid reading the mach timebase info ourselves.
        _ = std.c.clock_gettime(clocky.clock_id, @ptrCast(&spec));
        return spec;
    }

    if (comptime Environment.isLinux) {
        var spec = timespec{
            .nsec = 0,
            .sec = 0,
        };
        const clocky = struct {
            pub var clock_id: std.os.linux.CLOCK = .REALTIME;
            pub fn get() void {
                var res = timespec{};
                _ = std.os.linux.clock_getres(.MONOTONIC_COARSE, @ptrCast(&res));
                if (res.ms() <= 1) {
                    clock_id = .MONOTONIC_COARSE;
                } else {
                    clock_id = .MONOTONIC_RAW;
                }
            }

            pub var once = std.once(get);
        };
        clocky.once.call();
        _ = std.os.linux.clock_gettime(clocky.clock_id, @ptrCast(&spec));
        return spec;
    }

    if (comptime Environment.isWindows) {
        const ms = getRoughTickCountMs();
        return timespec{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * 1_000_000),
        };
    }

    return 0;
}

/// When you don't need a super accurate timestamp, this is a fast way to get one.
///
/// Requesting the current time frequently is somewhat expensive. So we can use a rough timestamp.
///
/// This timestamp doesn't easily correlate to a specific time. It's only useful relative to other calls.
pub fn getRoughTickCountMs() u64 {
    if (Environment.isWindows) {
        const GetTickCount64 = struct {
            pub extern "kernel32" fn GetTickCount64() std.os.windows.ULONGLONG;
        }.GetTickCount64;
        return GetTickCount64();
    }

    const spec = getRoughTickCount();
    return spec.ns() / std.time.ns_per_ms;
}

pub const timespec = extern struct {
    sec: isize = 0,
    nsec: isize = 0,

    pub fn eql(this: *const timespec, other: *const timespec) bool {
        return this.sec == other.sec and this.nsec == other.nsec;
    }

    pub fn toInstant(this: *const timespec) std.time.Instant {
        if (comptime Environment.isPosix) {
            return std.time.Instant{
                .timestamp = @bitCast(this.*),
            };
        }

        if (comptime Environment.isWindows) {
            return std.time.Instant{
                .timestamp = @intCast(this.sec * std.time.ns_per_s + this.nsec),
            };
        }
    }

    // TODO: this is wrong!
    pub fn duration(this: *const timespec, other: *const timespec) timespec {
        // Mimick C wrapping behavior.
        var sec_diff = this.sec -% other.sec;
        var nsec_diff = this.nsec -% other.nsec;

        if (nsec_diff < 0) {
            sec_diff -%= 1;
            nsec_diff +%= std.time.ns_per_s;
        }

        return timespec{
            .sec = sec_diff,
            .nsec = nsec_diff,
        };
    }

    pub fn order(a: *const timespec, b: *const timespec) std.math.Order {
        const sec_order = std.math.order(a.sec, b.sec);
        if (sec_order != .eq) return sec_order;
        return std.math.order(a.nsec, b.nsec);
    }

    /// Returns the nanoseconds of this timer. Note that maxInt(u64) ns is
    /// 584 years so if we get any overflows we just use maxInt(u64). If
    /// any software is running in 584 years waiting on this timer...
    /// shame on me I guess... but I'll be dead.
    pub fn ns(this: *const timespec) u64 {
        if (this.sec <= 0) {
            return @max(this.nsec, 0);
        }

        assert(this.sec >= 0);
        assert(this.nsec >= 0);
        const s_ns = std.math.mul(
            u64,
            @as(u64, @intCast(@max(this.sec, 0))),
            std.time.ns_per_s,
        ) catch return std.math.maxInt(u64);

        return std.math.add(u64, s_ns, @as(u64, @intCast(@max(this.nsec, 0)))) catch
            return std.math.maxInt(i64);
    }

    pub fn nsSigned(this: *const timespec) i64 {
        const ns_per_sec = this.sec *% std.time.ns_per_s;
        const ns_from_nsec = @divFloor(this.nsec, 1_000_000);
        return ns_per_sec +% ns_from_nsec;
    }

    pub fn ms(this: *const timespec) i64 {
        const ms_from_sec = this.sec *% 1000;
        const ms_from_nsec = @divFloor(this.nsec, 1_000_000);
        return ms_from_sec +% ms_from_nsec;
    }

    pub fn msUnsigned(this: *const timespec) u64 {
        return this.ns() / std.time.ns_per_ms;
    }

    pub fn greater(a: *const timespec, b: *const timespec) bool {
        return a.order(b) == .gt;
    }

    pub fn now() timespec {
        return getRoughTickCount();
    }

    pub fn sinceNow(start: *const timespec) u64 {
        return now().duration(start).ns();
    }

    pub fn addMs(this: *const timespec, interval: i64) timespec {
        const sec_inc = @divTrunc(interval, std.time.ms_per_s);
        const nsec_inc = @rem(interval, std.time.ms_per_s) * std.time.ns_per_ms;

        var new_timespec = this.*;

        new_timespec.sec +%= sec_inc;
        new_timespec.nsec +%= nsec_inc;

        if (new_timespec.nsec >= std.time.ns_per_s) {
            new_timespec.sec +%= 1;
            new_timespec.nsec -%= std.time.ns_per_s;
        }

        return new_timespec;
    }

    pub fn msFromNow(interval: i64) timespec {
        return now().addMs(interval);
    }
};

pub const UUID = @import("./bun.js/uuid.zig");

/// An abstract number of element in a sequence. The sequence has a first element.
/// This type should be used instead of integer because 2 contradicting traditions can
/// call a first element '0' or '1' which makes integer type ambiguous.
pub fn OrdinalT(comptime Int: type) type {
    return enum(Int) {
        invalid = switch (@typeInfo(Int).int.signedness) {
            .unsigned => std.math.maxInt(Int),
            .signed => -1,
        },
        start = 0,
        _,

        pub fn fromZeroBased(int: Int) @This() {
            assert(int >= 0);
            assert(int != std.math.maxInt(Int));
            return @enumFromInt(int);
        }

        pub fn fromOneBased(int: Int) @This() {
            assert(int > 0);
            return @enumFromInt(int - 1);
        }

        pub fn zeroBased(ord: @This()) Int {
            return @intFromEnum(ord);
        }

        pub fn oneBased(ord: @This()) Int {
            return @intFromEnum(ord) + 1;
        }

        pub fn add(ord: @This(), inc: Int) @This() {
            return fromZeroBased(ord.zeroBased() + inc);
        }

        pub fn isValid(ord: @This()) bool {
            return ord.zeroBased() >= 0;
        }
    };
}

/// ABI-equivalent of WTF::OrdinalNumber
pub const Ordinal = OrdinalT(c_int);

pub fn memmove(output: []u8, input: []const u8) void {
    if (output.len == 0) {
        return;
    }

    if (comptime Environment.allow_assert) {
        assert(output.len >= input.len);
    }

    if (Environment.isNative and !@inComptime()) {
        C.memmove(output.ptr, input.ptr, input.len);
    } else {
        for (input, output) |input_byte, *out| {
            out.* = input_byte;
        }
    }
}

pub const hmac = @import("./hmac.zig");
pub const libdeflate = @import("./deps/libdeflate.zig");

pub const bake = @import("bake/bake.zig");

/// like std.enums.tagName, except it doesn't lose the sentinel value.
pub fn tagName(comptime Enum: type, value: Enum) ?[:0]const u8 {
    return inline for (@typeInfo(Enum).@"enum".fields) |f| {
        if (@intFromEnum(value) == f.value) break f.name;
    } else null;
}
extern "c" fn Bun__ramSize() usize;
pub fn getTotalMemorySize() usize {
    return Bun__ramSize();
}

pub const DebugThreadLock = if (Environment.isDebug)
    struct {
        owning_thread: ?std.Thread.Id,
        locked_at: crash_handler.StoredTrace,

        pub const unlocked: DebugThreadLock = .{
            .owning_thread = null,
            .locked_at = crash_handler.StoredTrace.empty,
        };

        pub fn lock(impl: *@This()) void {
            if (impl.owning_thread) |thread| {
                Output.err("assertion failure", "Locked by thread {d} here:", .{thread});
                crash_handler.dumpStackTrace(impl.locked_at.trace(), .{ .frame_count = 10, .stop_at_jsc_llint = true });
                Output.panic("Safety lock violated on thread {d}", .{std.Thread.getCurrentId()});
            }
            impl.owning_thread = std.Thread.getCurrentId();
            impl.locked_at = crash_handler.StoredTrace.capture(@returnAddress());
        }

        pub fn unlock(impl: *@This()) void {
            impl.assertLocked();
            impl.* = unlocked;
        }

        pub fn assertLocked(impl: *const @This()) void {
            assert(impl.owning_thread != null); // not locked
            assert(impl.owning_thread == std.Thread.getCurrentId());
        }

        pub fn initLocked() @This() {
            var impl = DebugThreadLock.unlocked;
            impl.lock();
            return impl;
        }
    }
else
    struct {
        pub const unlocked: @This() = .{};
        pub fn lock(_: *@This()) void {}
        pub fn unlock(_: *@This()) void {}
        pub fn assertLocked(_: *const @This()) void {}
        pub fn initLocked() @This() {
            return .{};
        }
    };

pub const bytecode_extension = ".jsc";

/// An typed index into an array or other structure.
/// maxInt is reserved for an empty state.
///
/// const Thing = struct {};
/// const Index = bun.GenericIndex(u32, Thing)
///
/// The second argument prevents Zig from memoizing the
/// call, which would otherwise make all indexes
/// equal to each other.
pub fn GenericIndex(backing_int: type, uid: anytype) type {
    const null_value = std.math.maxInt(backing_int);
    return enum(backing_int) {
        _,
        const Index = @This();
        comptime {
            _ = uid;
        }

        /// Prefer this over @enumFromInt to assert the int is in range
        pub inline fn init(int: backing_int) Index {
            bun.assert(int != null_value); // would be confused for null
            return @enumFromInt(int);
        }

        /// Prefer this over @intFromEnum because of type confusion with `.Optional`
        pub inline fn get(i: @This()) backing_int {
            bun.assert(@intFromEnum(i) != null_value); // memory corruption
            return @intFromEnum(i);
        }

        pub inline fn toOptional(oi: @This()) Optional {
            return @enumFromInt(oi.get());
        }

        pub fn sortFnAsc(_: void, a: @This(), b: @This()) bool {
            return a.get() < b.get();
        }

        pub fn sortFnDesc(_: void, a: @This(), b: @This()) bool {
            return a.get() < b.get();
        }

        pub fn format(this: @This(), comptime f: []const u8, opts: std.fmt.FormatOptions, writer: anytype) !void {
            comptime if (strings.eql(f, "d") or strings.eql(f, "any"))
                @compileError("Invalid format specifier: " ++ f);
            try std.fmt.formatInt(@intFromEnum(this), 10, .lower, opts, writer);
        }

        pub const Optional = enum(backing_int) {
            none = std.math.maxInt(backing_int),
            _,

            /// Signatures:
            /// - `init(maybe: ?Index) Optional`
            /// - `init(maybe: ?backing_int) Optional`
            pub inline fn init(maybe: anytype) Optional {
                comptime var t = @typeInfo(@TypeOf(maybe));
                if (t == .optional) t = @typeInfo(t.optional.child);
                if (t == .int or t == .comptime_int)
                    return if (@as(?backing_int, maybe)) |i| Index.init(i).toOptional() else .none;
                return if (@as(?Index, maybe)) |i| i.toOptional() else .none;
            }

            pub inline fn unwrap(oi: Optional) ?Index {
                return if (oi == .none) null else @enumFromInt(@intFromEnum(oi));
            }
        };
    };
}

comptime {
    // Must be nominal
    assert(GenericIndex(u32, opaque {}) != GenericIndex(u32, opaque {}));
}

pub fn splitAtMut(comptime T: type, slice: []T, mid: usize) struct { []T, []T } {
    bun.assert(mid <= slice.len);

    return .{ slice[0..mid], slice[mid..] };
}

/// Reverse of the slice index operator.
/// Given `&slice[index] == item`, returns the `index` needed.
/// The item must be in the slice.
pub fn indexOfPointerInSlice(comptime T: type, slice: []const T, item: *const T) usize {
    bun.assert(isSliceInBufferT(T, item[0..1], slice));
    const offset = @intFromPtr(item) - @intFromPtr(slice.ptr);
    const index = @divExact(offset, @sizeOf(T));
    return index;
}

pub fn getThreadCount() u16 {
    const max_threads = 1024;
    const min_threads = 2;
    const ThreadCount = struct {
        pub var cached_thread_count: u16 = 0;
        var cached_thread_count_once = std.once(getThreadCountOnce);
        fn getThreadCountFromUser() ?u16 {
            inline for (.{ "UV_THREADPOOL_SIZE", "GOMAXPROCS" }) |envname| {
                if (getenvZ(envname)) |env| {
                    if (std.fmt.parseInt(u16, env, 10) catch null) |parsed| {
                        if (parsed >= min_threads) {
                            if (bun.logger.Log.default_log_level.atLeast(.debug)) {
                                Output.note("Using {d} threads from {s}={d}", .{ parsed, envname, parsed });
                                Output.flush();
                            }
                            return @min(parsed, max_threads);
                        }
                    }
                }
            }

            return null;
        }
        fn getThreadCountOnce() void {
            cached_thread_count = @min(max_threads, @max(min_threads, getThreadCountFromUser() orelse std.Thread.getCpuCount() catch 0));
        }
    };
    ThreadCount.cached_thread_count_once.call();
    return ThreadCount.cached_thread_count;
}

/// Copied from zig std. Modified to accept arguments.
pub fn once(comptime f: anytype) Once(f) {
    return Once(f){};
}

/// Copied from zig std. Modified to accept arguments.
///
/// An object that executes the function `f` just once.
/// It is undefined behavior if `f` re-enters the same Once instance.
pub fn Once(comptime f: anytype) type {
    return struct {
        const Return = @typeInfo(@TypeOf(f)).@"fn".return_type.?;

        done: bool = false,
        payload: Return = undefined,
        mutex: bun.Mutex = .{},

        /// Call the function `f`.
        /// If `call` is invoked multiple times `f` will be executed only the
        /// first time.
        /// The invocations are thread-safe.
        pub fn call(self: *@This(), args: std.meta.ArgsTuple(@TypeOf(f))) Return {
            if (@atomicLoad(bool, &self.done, .acquire))
                return self.payload;

            return self.callSlow(args);
        }

        fn callSlow(self: *@This(), args: std.meta.ArgsTuple(@TypeOf(f))) Return {
            @branchHint(.cold);

            self.mutex.lock();
            defer self.mutex.unlock();

            // The first thread to acquire the mutex gets to run the initializer
            if (!self.done) {
                self.payload = @call(.auto, f, args);
                @atomicStore(bool, &self.done, true, .release);
            }

            return self.payload;
        }
    };
}

/// `val` must be a pointer to an optional type (e.g. `*?T`)
///
/// This function takes the value out of the optional, replacing it with null, and returns the value.
pub inline fn take(val: anytype) ?@typeInfo(@typeInfo(@TypeOf(val)).pointer.child).optional.child {
    if (val.*) |v| {
        val.* = null;
        return v;
    }
    return null;
}

/// `val` must be a pointer to an optional type (e.g. `*?T`)
///
/// This function deinitializes the value and sets the optional to null.
pub inline fn clear(val: anytype, allocator: std.mem.Allocator) void {
    if (val.*) |*v| {
        v.deinit(allocator);
        val.* = null;
    }
}

pub inline fn wrappingNegation(val: anytype) @TypeOf(val) {
    return 0 -% val;
}

fn assertNoPointers(T: type) void {
    switch (@typeInfo(T)) {
        .pointer => @compileError("no pointers!"),
        inline .@"struct", .@"union" => |s| for (s.fields) |field| {
            assertNoPointers(field.type);
        },
        .array => |a| assertNoPointers(a.child),
        else => {},
    }
}

pub inline fn writeAnyToHasher(hasher: anytype, thing: anytype) void {
    comptime assertNoPointers(@TypeOf(thing)); // catch silly mistakes
    hasher.update(std.mem.asBytes(&thing));
}

pub const perf = @import("./perf.zig");
pub inline fn isComptimeKnown(x: anytype) bool {
    return comptime @typeInfo(@TypeOf(.{x})).@"struct".fields[0].is_comptime;
}

pub inline fn itemOrNull(comptime T: type, slice: []const T, index: usize) ?T {
    return if (index < slice.len) slice[index] else null;
}

pub const Maybe = bun.JSC.Node.Maybe;

/// To handle stack overflows:
/// 1. StackCheck.init()
/// 2. .isSafeToRecurse()
pub const StackCheck = struct {
    cached_stack_end: usize = 0,

    extern fn Bun__StackCheck__initialize() void;
    pub fn configureThread() void {
        Bun__StackCheck__initialize();
    }

    extern "c" fn Bun__StackCheck__getMaxStack() usize;
    fn getStackEnd() usize {
        return Bun__StackCheck__getMaxStack();
    }

    pub fn init() StackCheck {
        return StackCheck{ .cached_stack_end = getStackEnd() };
    }

    pub fn update(this: *StackCheck) void {
        this.cached_stack_end = getStackEnd();
    }

    /// Is there at least 128 KB of stack space available?
    pub fn isSafeToRecurse(this: StackCheck) bool {
        const stack_ptr: usize = @frameAddress();
        const remaining_stack = stack_ptr -| this.cached_stack_end;
        return remaining_stack > 1024 * if (Environment.isWindows) 256 else 128;
    }
};

// Workaround for lack of branch hints.
pub noinline fn throwStackOverflow() StackOverflow!void {
    @branchHint(.cold);
    return error.StackOverflow;
}
const StackOverflow = error{StackOverflow};

// This pool exists because on Windows, each path buffer costs 64 KB.
// This makes the stack memory usage very unpredictable, which means we can't really know how much stack space we have left.
// This pool is a workaround to make the stack memory usage more predictable.
// We keep up to 4 path buffers alive per thread at a time.
pub fn PathBufferPoolT(comptime T: type) type {
    return struct {
        const Pool = ObjectPool(PathBuf, null, true, 4);
        pub const PathBuf = struct {
            bytes: T,

            pub fn deinit(this: *PathBuf) void {
                var node: *Pool.Node = @alignCast(@fieldParentPtr("data", this));
                node.release();
            }
        };

        pub fn get() *T {
            // use a threadlocal allocator so mimalloc deletes it on thread deinit.
            return &Pool.get(bun.threadlocalAllocator()).data.bytes;
        }

        pub fn put(buffer: *T) void {
            var path_buf: *PathBuf = @alignCast(@fieldParentPtr("bytes", buffer));
            path_buf.deinit();
        }

        pub fn deleteAll() void {
            Pool.deleteAll();
        }
    };
}

pub const PathBufferPool = PathBufferPoolT(bun.PathBuffer);
pub const WPathBufferPool = if (Environment.isWindows) PathBufferPoolT(bun.WPathBuffer) else struct {
    // So it can be used in code that deletes all the pools.
    pub fn deleteAll() void {}
};
pub const OSPathBufferPool = if (Environment.isWindows) WPathBufferPool else PathBufferPool;

pub const S3 = @import("./s3/client.zig");
pub const ptr = @import("./ptr.zig");

const Allocator = std.mem.Allocator;

/// Memory is typically not decommitted immediately when freed.
/// Sensitive information that's kept in memory can be read in various ways until the OS
/// decommits it or the memory allocator reuses it for a new allocation.
/// So if we're about to free something sensitive, we should zero it out first.
pub fn freeSensitive(allocator: std.mem.Allocator, slice: anytype) void {
    @memset(@constCast(slice), 0);
    allocator.free(slice);
}

pub const server = @import("./bun.js/api/server.zig");
pub const macho = @import("./macho.zig");
pub const valkey = @import("./valkey/index.zig");
