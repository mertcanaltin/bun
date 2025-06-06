const std = @import("std");
const JSC = bun.JSC;
const VirtualMachine = bun.JSC.VirtualMachine;
const Allocator = std.mem.Allocator;
const Lock = bun.Mutex;
const bun = @import("root").bun;
const Environment = bun.Environment;
const Fetch = JSC.WebCore.Fetch;
const Bun = JSC.API.Bun;
const TaggedPointerUnion = @import("../ptr.zig").TaggedPointerUnion;
const typeBaseName = @import("../meta.zig").typeBaseName;
const AsyncGlobWalkTask = JSC.API.Glob.WalkTask.AsyncGlobWalkTask;
const CopyFilePromiseTask = bun.JSC.WebCore.Blob.Store.CopyFilePromiseTask;
const AsyncTransformTask = JSC.API.JSTranspiler.TransformTask.AsyncTransformTask;
const ReadFileTask = bun.JSC.WebCore.Blob.ReadFileTask;
const WriteFileTask = bun.JSC.WebCore.Blob.WriteFileTask;
const napi_async_work = JSC.napi.napi_async_work;
const FetchTasklet = Fetch.FetchTasklet;
const S3 = bun.S3;
const S3HttpSimpleTask = S3.S3HttpSimpleTask;
const S3HttpDownloadStreamingTask = S3.S3HttpDownloadStreamingTask;
const NapiFinalizerTask = bun.JSC.napi.NapiFinalizerTask;

const Waker = bun.Async.Waker;

pub const WorkPool = @import("../work_pool.zig").WorkPool;
pub const WorkPoolTask = @import("../work_pool.zig").Task;

const uws = bun.uws;
const Async = bun.Async;

pub fn ConcurrentPromiseTask(comptime Context: type) type {
    return struct {
        const This = @This();
        ctx: *Context,
        task: WorkPoolTask = .{ .callback = &runFromThreadPool },
        event_loop: *JSC.EventLoop,
        allocator: std.mem.Allocator,
        promise: JSC.JSPromise.Strong = .{},
        globalThis: *JSC.JSGlobalObject,
        concurrent_task: JSC.ConcurrentTask = .{},

        // This is a poll because we want it to enter the uSockets loop
        ref: Async.KeepAlive = .{},

        pub const new = bun.TrivialNew(@This());

        pub fn createOnJSThread(allocator: std.mem.Allocator, globalThis: *JSC.JSGlobalObject, value: *Context) !*This {
            var this = This.new(.{
                .event_loop = VirtualMachine.get().event_loop,
                .ctx = value,
                .allocator = allocator,
                .globalThis = globalThis,
            });
            var promise = JSC.JSPromise.create(globalThis);
            this.promise.strong.set(globalThis, promise.asValue(globalThis));
            this.ref.ref(this.event_loop.virtual_machine);

            return this;
        }

        pub fn runFromThreadPool(task: *WorkPoolTask) void {
            var this: *This = @fieldParentPtr("task", task);
            Context.run(this.ctx);
            this.onFinish();
        }

        pub fn runFromJS(this: *This) void {
            const promise = this.promise.swap();
            this.ref.unref(this.event_loop.virtual_machine);

            var ctx = this.ctx;

            ctx.then(promise);
        }

        pub fn schedule(this: *This) void {
            WorkPool.schedule(&this.task);
        }

        pub fn onFinish(this: *This) void {
            this.event_loop.enqueueTaskConcurrent(this.concurrent_task.from(this, .manual_deinit));
        }

        pub fn deinit(this: *This) void {
            this.promise.deinit();
            bun.destroy(this);
        }
    };
}

pub fn WorkTask(comptime Context: type) type {
    return struct {
        const TaskType = WorkPoolTask;

        const This = @This();
        ctx: *Context,
        task: TaskType = .{ .callback = &runFromThreadPool },
        event_loop: *JSC.EventLoop,
        allocator: std.mem.Allocator,
        globalThis: *JSC.JSGlobalObject,
        concurrent_task: ConcurrentTask = .{},
        async_task_tracker: JSC.AsyncTaskTracker,

        // This is a poll because we want it to enter the uSockets loop
        ref: Async.KeepAlive = .{},

        pub fn createOnJSThread(allocator: std.mem.Allocator, globalThis: *JSC.JSGlobalObject, value: *Context) !*This {
            var vm = globalThis.bunVM();
            var this = bun.new(This, .{
                .event_loop = vm.eventLoop(),
                .ctx = value,
                .allocator = allocator,
                .globalThis = globalThis,
                .async_task_tracker = JSC.AsyncTaskTracker.init(vm),
            });
            this.ref.ref(this.event_loop.virtual_machine);

            return this;
        }

        pub fn deinit(this: *This) void {
            this.ref.unref(this.event_loop.virtual_machine);
            bun.destroy(this);
        }

        pub fn runFromThreadPool(task: *TaskType) void {
            JSC.markBinding(@src());
            const this: *This = @fieldParentPtr("task", task);
            Context.run(this.ctx, this);
        }

        pub fn runFromJS(this: *This) void {
            var ctx = this.ctx;
            const tracker = this.async_task_tracker;
            const vm = this.event_loop.virtual_machine;
            const globalThis = this.globalThis;
            this.ref.unref(vm);

            tracker.willDispatch(globalThis);
            ctx.then(globalThis);
            tracker.didDispatch(globalThis);
        }

        pub fn schedule(this: *This) void {
            const vm = this.event_loop.virtual_machine;
            this.ref.ref(vm);
            this.async_task_tracker.didSchedule(this.globalThis);
            WorkPool.schedule(&this.task);
        }

        pub fn onFinish(this: *This) void {
            this.event_loop.enqueueTaskConcurrent(this.concurrent_task.from(this, .manual_deinit));
        }
    };
}

pub const AnyTask = struct {
    ctx: ?*anyopaque,
    callback: *const (fn (*anyopaque) void),

    pub fn task(this: *AnyTask) Task {
        return Task.init(this);
    }

    pub fn run(this: *AnyTask) void {
        @setRuntimeSafety(false);
        const callback = this.callback;
        const ctx = this.ctx;
        callback(ctx.?);
    }

    pub fn New(comptime Type: type, comptime Callback: anytype) type {
        return struct {
            pub fn init(ctx: *Type) AnyTask {
                return AnyTask{
                    .callback = wrap,
                    .ctx = ctx,
                };
            }

            pub fn wrap(this: ?*anyopaque) void {
                @call(bun.callmod_inline, Callback, .{@as(*Type, @ptrCast(@alignCast(this.?)))});
            }
        };
    }
};

pub const ManagedTask = struct {
    ctx: ?*anyopaque,
    callback: *const (fn (*anyopaque) void),

    pub fn task(this: *ManagedTask) Task {
        return Task.init(this);
    }

    pub fn run(this: *ManagedTask) void {
        @setRuntimeSafety(false);
        const callback = this.callback;
        const ctx = this.ctx;
        callback(ctx.?);
        bun.default_allocator.destroy(this);
    }

    pub fn cancel(this: *ManagedTask) void {
        this.callback = &struct {
            fn f(_: *anyopaque) void {}
        }.f;
    }

    pub fn New(comptime Type: type, comptime Callback: anytype) type {
        return struct {
            pub fn init(ctx: *Type) Task {
                var managed = bun.default_allocator.create(ManagedTask) catch bun.outOfMemory();
                managed.* = ManagedTask{
                    .callback = wrap,
                    .ctx = ctx,
                };
                return managed.task();
            }

            pub fn wrap(this: ?*anyopaque) void {
                @call(bun.callmod_inline, Callback, .{@as(*Type, @ptrCast(@alignCast(this.?)))});
            }
        };
    }
};

pub const AnyTaskWithExtraContext = struct {
    ctx: ?*anyopaque = undefined,
    callback: *const (fn (*anyopaque, *anyopaque) void) = undefined,
    next: ?*AnyTaskWithExtraContext = null,

    pub fn fromCallbackAutoDeinit(ptr: anytype, comptime fieldName: [:0]const u8) *AnyTaskWithExtraContext {
        const Ptr = std.meta.Child(@TypeOf(ptr));
        const Wrapper = struct {
            any_task: AnyTaskWithExtraContext,
            wrapped: *Ptr,
            pub fn function(this: *anyopaque, extra: *anyopaque) void {
                const that: *@This() = @ptrCast(@alignCast(this));
                defer bun.default_allocator.destroy(that);
                const ctx = that.wrapped;
                @field(Ptr, fieldName)(ctx, extra);
            }
        };
        const task = bun.default_allocator.create(Wrapper) catch bun.outOfMemory();
        task.* = Wrapper{
            .any_task = AnyTaskWithExtraContext{
                .callback = &Wrapper.function,
                .ctx = task,
            },
            .wrapped = ptr,
        };
        return &task.any_task;
    }

    pub fn from(this: *@This(), of: anytype, comptime field: []const u8) *@This() {
        const TheTask = New(std.meta.Child(@TypeOf(of)), void, @field(std.meta.Child(@TypeOf(of)), field));
        this.* = TheTask.init(of);
        return this;
    }

    pub fn run(this: *AnyTaskWithExtraContext, extra: *anyopaque) void {
        @setRuntimeSafety(false);
        const callback = this.callback;
        const ctx = this.ctx;
        callback(ctx.?, extra);
    }

    pub fn New(comptime Type: type, comptime ContextType: type, comptime Callback: anytype) type {
        return struct {
            pub fn init(ctx: *Type) AnyTaskWithExtraContext {
                return AnyTaskWithExtraContext{
                    .callback = wrap,
                    .ctx = ctx,
                };
            }

            pub fn wrap(this: ?*anyopaque, extra: ?*anyopaque) void {
                @call(
                    .always_inline,
                    Callback,
                    .{
                        @as(*Type, @ptrCast(@alignCast(this.?))),
                        @as(*ContextType, @ptrCast(@alignCast(extra.?))),
                    },
                );
            }
        };
    }
};

pub const CppTask = opaque {
    extern fn Bun__performTask(globalObject: *JSC.JSGlobalObject, task: *CppTask) void;
    pub fn run(this: *CppTask, global: *JSC.JSGlobalObject) void {
        JSC.markBinding(@src());
        Bun__performTask(global, this);
    }
};

pub const ConcurrentCppTask = struct {
    pub const new = bun.TrivialNew(@This());

    cpp_task: *EventLoopTaskNoContext,
    workpool_task: JSC.WorkPoolTask = .{ .callback = &runFromWorkpool },

    const EventLoopTaskNoContext = opaque {
        extern fn Bun__EventLoopTaskNoContext__performTask(task: *EventLoopTaskNoContext) void;
        extern fn Bun__EventLoopTaskNoContext__createdInBunVm(task: *const EventLoopTaskNoContext) ?*VirtualMachine;

        /// Deallocates `this`
        pub fn run(this: *EventLoopTaskNoContext) void {
            Bun__EventLoopTaskNoContext__performTask(this);
        }

        /// Get the VM that created this task
        pub fn getVM(this: *const EventLoopTaskNoContext) ?*VirtualMachine {
            return Bun__EventLoopTaskNoContext__createdInBunVm(this);
        }
    };

    pub fn runFromWorkpool(task: *JSC.WorkPoolTask) void {
        const this: *ConcurrentCppTask = @fieldParentPtr("workpool_task", task);
        // Extract all the info we need from `this` and `cpp_task` before we call functions that
        // free them
        const cpp_task = this.cpp_task;
        const maybe_vm = cpp_task.getVM();
        bun.destroy(this);
        cpp_task.run();
        if (maybe_vm) |vm| {
            vm.event_loop.unrefConcurrently();
        }
    }

    pub export fn ConcurrentCppTask__createAndRun(cpp_task: *EventLoopTaskNoContext) void {
        JSC.markBinding(@src());
        if (cpp_task.getVM()) |vm| {
            vm.event_loop.refConcurrently();
        }
        const cpp = ConcurrentCppTask.new(.{ .cpp_task = cpp_task });
        JSC.WorkPool.schedule(&cpp.workpool_task);
    }
};

comptime {
    _ = ConcurrentCppTask.ConcurrentCppTask__createAndRun;
}

pub const JSCScheduler = struct {
    pub const JSCDeferredWorkTask = opaque {
        extern fn Bun__runDeferredWork(task: *JSCScheduler.JSCDeferredWorkTask) void;
        pub const run = Bun__runDeferredWork;
    };

    export fn Bun__eventLoop__incrementRefConcurrently(jsc_vm: *VirtualMachine, delta: c_int) void {
        JSC.markBinding(@src());

        if (delta > 0) {
            jsc_vm.event_loop.refConcurrently();
        } else {
            jsc_vm.event_loop.unrefConcurrently();
        }
    }

    export fn Bun__queueJSCDeferredWorkTaskConcurrently(jsc_vm: *VirtualMachine, task: *JSCScheduler.JSCDeferredWorkTask) void {
        JSC.markBinding(@src());
        var loop = jsc_vm.eventLoop();
        loop.enqueueTaskConcurrent(ConcurrentTask.new(.{
            .task = Task.init(task),
            .next = null,
            .auto_delete = true,
        }));
    }

    comptime {
        _ = Bun__eventLoop__incrementRefConcurrently;
        _ = Bun__queueJSCDeferredWorkTaskConcurrently;
    }
};

const ThreadSafeFunction = JSC.napi.ThreadSafeFunction;
const HotReloadTask = JSC.HotReloader.HotReloadTask;
const FSWatchTask = JSC.Node.FSWatcher.FSWatchTask;
const PollPendingModulesTask = JSC.ModuleLoader.AsyncModule.Queue;
// const PromiseTask = JSInternalPromise.Completion.PromiseTask;
const GetAddrInfoRequestTask = JSC.DNS.GetAddrInfoRequest.Task;
const JSCDeferredWorkTask = JSCScheduler.JSCDeferredWorkTask;

const Stat = JSC.Node.Async.stat;
const Lstat = JSC.Node.Async.lstat;
const Fstat = JSC.Node.Async.fstat;
const Open = JSC.Node.Async.open;
const ReadFile = JSC.Node.Async.readFile;
const WriteFile = JSC.Node.Async.writeFile;
const CopyFile = JSC.Node.Async.copyFile;
const Read = JSC.Node.Async.read;
const Write = JSC.Node.Async.write;
const Truncate = JSC.Node.Async.truncate;
const FTruncate = JSC.Node.Async.ftruncate;
const Readdir = JSC.Node.Async.readdir;
const ReaddirRecursive = JSC.Node.Async.readdir_recursive;
const Readv = JSC.Node.Async.readv;
const Writev = JSC.Node.Async.writev;
const Close = JSC.Node.Async.close;
const Rm = JSC.Node.Async.rm;
const Rmdir = JSC.Node.Async.rmdir;
const Chown = JSC.Node.Async.chown;
const FChown = JSC.Node.Async.fchown;
const Utimes = JSC.Node.Async.utimes;
const Lutimes = JSC.Node.Async.lutimes;
const Chmod = JSC.Node.Async.chmod;
const Fchmod = JSC.Node.Async.fchmod;
const Link = JSC.Node.Async.link;
const Symlink = JSC.Node.Async.symlink;
const Readlink = JSC.Node.Async.readlink;
const Realpath = JSC.Node.Async.realpath;
const RealpathNonNative = JSC.Node.Async.realpathNonNative;
const Mkdir = JSC.Node.Async.mkdir;
const Fsync = JSC.Node.Async.fsync;
const Rename = JSC.Node.Async.rename;
const Fdatasync = JSC.Node.Async.fdatasync;
const Access = JSC.Node.Async.access;
const AppendFile = JSC.Node.Async.appendFile;
const Mkdtemp = JSC.Node.Async.mkdtemp;
const Exists = JSC.Node.Async.exists;
const Futimes = JSC.Node.Async.futimes;
const Lchmod = JSC.Node.Async.lchmod;
const Lchown = JSC.Node.Async.lchown;
const StatFS = JSC.Node.Async.statfs;
const Unlink = JSC.Node.Async.unlink;
const NativeZlib = JSC.API.NativeZlib;
const NativeBrotli = JSC.API.NativeBrotli;

const ShellGlobTask = bun.shell.interpret.Interpreter.Expansion.ShellGlobTask;
const ShellRmTask = bun.shell.Interpreter.Builtin.Rm.ShellRmTask;
const ShellRmDirTask = bun.shell.Interpreter.Builtin.Rm.ShellRmTask.DirTask;
const ShellLsTask = bun.shell.Interpreter.Builtin.Ls.ShellLsTask;
const ShellMvCheckTargetTask = bun.shell.Interpreter.Builtin.Mv.ShellMvCheckTargetTask;
const ShellMvBatchedTask = bun.shell.Interpreter.Builtin.Mv.ShellMvBatchedTask;
const ShellMkdirTask = bun.shell.Interpreter.Builtin.Mkdir.ShellMkdirTask;
const ShellTouchTask = bun.shell.Interpreter.Builtin.Touch.ShellTouchTask;
const ShellCpTask = bun.shell.Interpreter.Builtin.Cp.ShellCpTask;
const ShellCondExprStatTask = bun.shell.Interpreter.CondExpr.ShellCondExprStatTask;
const ShellAsync = bun.shell.Interpreter.Async;
// const ShellIOReaderAsyncDeinit = bun.shell.Interpreter.IOReader.AsyncDeinit;
const ShellIOReaderAsyncDeinit = bun.shell.Interpreter.AsyncDeinitReader;
const ShellIOWriterAsyncDeinit = bun.shell.Interpreter.AsyncDeinitWriter;
const TimeoutObject = JSC.BunTimer.TimeoutObject;
const ImmediateObject = JSC.BunTimer.ImmediateObject;
const ProcessWaiterThreadTask = if (Environment.isPosix) bun.spawn.WaiterThread.ProcessQueue.ResultTask else opaque {};
const ProcessMiniEventLoopWaiterThreadTask = if (Environment.isPosix) bun.spawn.WaiterThread.ProcessMiniEventLoopQueue.ResultTask else opaque {};
const ShellAsyncSubprocessDone = bun.shell.Interpreter.Cmd.ShellAsyncSubprocessDone;
const RuntimeTranspilerStore = JSC.RuntimeTranspilerStore;
const ServerAllConnectionsClosedTask = @import("./api/server.zig").ServerAllConnectionsClosedTask;
const FlushPendingFileSinkTask = JSC.WebCore.FlushPendingFileSinkTask;

// Task.get(ReadFileTask) -> ?ReadFileTask
pub const Task = TaggedPointerUnion(.{
    Access,
    AnyTask,
    AppendFile,
    AsyncGlobWalkTask,
    AsyncTransformTask,
    bun.bake.DevServer.HotReloadEvent,
    bun.bundle_v2.DeferredBatchTask,
    bun.shell.Interpreter.Builtin.Yes.YesTask,
    Chmod,
    Chown,
    Close,
    CopyFile,
    CopyFilePromiseTask,
    CppTask,
    Exists,
    Fchmod,
    FChown,
    Fdatasync,
    FetchTasklet,
    Fstat,
    FSWatchTask,
    Fsync,
    FTruncate,
    Futimes,
    GetAddrInfoRequestTask,
    HotReloadTask,
    ImmediateObject,
    JSCDeferredWorkTask,
    Lchmod,
    Lchown,
    Link,
    Lstat,
    Lutimes,
    ManagedTask,
    Mkdir,
    Mkdtemp,
    napi_async_work,
    NapiFinalizerTask,
    NativeBrotli,
    NativeZlib,
    Open,
    PollPendingModulesTask,
    PosixSignalTask,
    ProcessWaiterThreadTask,
    Read,
    Readdir,
    ReaddirRecursive,
    ReadFile,
    ReadFileTask,
    Readlink,
    Readv,
    FlushPendingFileSinkTask,
    Realpath,
    RealpathNonNative,
    Rename,
    Rm,
    Rmdir,
    RuntimeTranspilerStore,
    S3HttpDownloadStreamingTask,
    S3HttpSimpleTask,
    ServerAllConnectionsClosedTask,
    ShellAsync,
    ShellAsyncSubprocessDone,
    ShellCondExprStatTask,
    ShellCpTask,
    ShellGlobTask,
    ShellIOReaderAsyncDeinit,
    ShellIOWriterAsyncDeinit,
    ShellLsTask,
    ShellMkdirTask,
    ShellMvBatchedTask,
    ShellMvCheckTargetTask,
    ShellRmDirTask,
    ShellRmTask,
    ShellTouchTask,
    Stat,
    StatFS,
    Symlink,
    ThreadSafeFunction,
    TimeoutObject,
    Truncate,
    Unlink,
    Utimes,
    Write,
    WriteFile,
    WriteFileTask,
    Writev,
});
const UnboundedQueue = @import("./unbounded_queue.zig").UnboundedQueue;
pub const ConcurrentTask = struct {
    task: Task = undefined,
    next: ?*ConcurrentTask = null,
    auto_delete: bool = false,

    pub const Queue = UnboundedQueue(ConcurrentTask, .next);
    pub const new = bun.TrivialNew(@This());
    pub const deinit = bun.TrivialDeinit(@This());

    pub const AutoDeinit = enum {
        manual_deinit,
        auto_deinit,
    };
    pub fn create(task: Task) *ConcurrentTask {
        return ConcurrentTask.new(.{
            .task = task,
            .next = null,
            .auto_delete = true,
        });
    }

    pub fn createFrom(task: anytype) *ConcurrentTask {
        JSC.markBinding(@src());
        return create(Task.init(task));
    }

    pub fn fromCallback(ptr: anytype, comptime callback: anytype) *ConcurrentTask {
        JSC.markBinding(@src());

        return create(ManagedTask.New(std.meta.Child(@TypeOf(ptr)), callback).init(ptr));
    }

    pub fn from(this: *ConcurrentTask, of: anytype, auto_deinit: AutoDeinit) *ConcurrentTask {
        JSC.markBinding(@src());

        this.* = .{
            .task = Task.init(of),
            .next = null,
            .auto_delete = auto_deinit == .auto_deinit,
        };
        return this;
    }
};

// This type must be unique per JavaScript thread
pub const GarbageCollectionController = struct {
    gc_timer: *uws.Timer = undefined,
    gc_last_heap_size: usize = 0,
    gc_last_heap_size_on_repeating_timer: usize = 0,
    heap_size_didnt_change_for_repeating_timer_ticks_count: u8 = 0,
    gc_timer_state: GCTimerState = GCTimerState.pending,
    gc_repeating_timer: *uws.Timer = undefined,
    gc_timer_interval: i32 = 0,
    gc_repeating_timer_fast: bool = true,
    disabled: bool = false,

    pub fn init(this: *GarbageCollectionController, vm: *VirtualMachine) void {
        const actual = uws.Loop.get();
        this.gc_timer = uws.Timer.createFallthrough(actual, this);
        this.gc_repeating_timer = uws.Timer.createFallthrough(actual, this);
        actual.internal_loop_data.jsc_vm = vm.jsc;

        if (comptime Environment.isDebug) {
            if (bun.getenvZ("BUN_TRACK_LAST_FN_NAME") != null) {
                vm.eventLoop().debug.track_last_fn_name = true;
            }
        }

        var gc_timer_interval: i32 = 1000;
        if (vm.transpiler.env.get("BUN_GC_TIMER_INTERVAL")) |timer| {
            if (std.fmt.parseInt(i32, timer, 10)) |parsed| {
                if (parsed > 0) {
                    gc_timer_interval = parsed;
                }
            } else |_| {}
        }
        this.gc_timer_interval = gc_timer_interval;

        this.disabled = vm.transpiler.env.has("BUN_GC_TIMER_DISABLE");

        if (!this.disabled)
            this.gc_repeating_timer.set(this, onGCRepeatingTimer, gc_timer_interval, gc_timer_interval);
    }

    pub fn scheduleGCTimer(this: *GarbageCollectionController) void {
        this.gc_timer_state = .scheduled;
        this.gc_timer.set(this, onGCTimer, 16, 0);
    }

    pub fn bunVM(this: *GarbageCollectionController) *VirtualMachine {
        return @alignCast(@fieldParentPtr("gc_controller", this));
    }

    pub fn onGCTimer(timer: *uws.Timer) callconv(.C) void {
        var this = timer.as(*GarbageCollectionController);
        if (this.disabled) return;
        this.gc_timer_state = .run_on_next_tick;
    }

    // We want to always run GC once in awhile
    // But if you have a long-running instance of Bun, you don't want the
    // program constantly using CPU doing GC for no reason
    //
    // So we have two settings for this GC timer:
    //
    //    - Fast: GC runs every 1 second
    //    - Slow: GC runs every 30 seconds
    //
    // When the heap size is increasing, we always switch to fast mode
    // When the heap size has been the same or less for 30 seconds, we switch to slow mode
    pub fn updateGCRepeatTimer(this: *GarbageCollectionController, comptime setting: @Type(.enum_literal)) void {
        if (setting == .fast and !this.gc_repeating_timer_fast) {
            this.gc_repeating_timer_fast = true;
            this.gc_repeating_timer.set(this, onGCRepeatingTimer, this.gc_timer_interval, this.gc_timer_interval);
            this.heap_size_didnt_change_for_repeating_timer_ticks_count = 0;
        } else if (setting == .slow and this.gc_repeating_timer_fast) {
            this.gc_repeating_timer_fast = false;
            this.gc_repeating_timer.set(this, onGCRepeatingTimer, 30_000, 30_000);
            this.heap_size_didnt_change_for_repeating_timer_ticks_count = 0;
        }
    }

    pub fn onGCRepeatingTimer(timer: *uws.Timer) callconv(.C) void {
        var this = timer.as(*GarbageCollectionController);
        const prev_heap_size = this.gc_last_heap_size_on_repeating_timer;
        this.performGC();
        this.gc_last_heap_size_on_repeating_timer = this.gc_last_heap_size;
        if (prev_heap_size == this.gc_last_heap_size_on_repeating_timer) {
            this.heap_size_didnt_change_for_repeating_timer_ticks_count +|= 1;
            if (this.heap_size_didnt_change_for_repeating_timer_ticks_count >= 30) {
                // make the timer interval longer
                this.updateGCRepeatTimer(.slow);
            }
        } else {
            this.heap_size_didnt_change_for_repeating_timer_ticks_count = 0;
            this.updateGCRepeatTimer(.fast);
        }
    }

    pub fn processGCTimer(this: *GarbageCollectionController) void {
        if (this.disabled) return;
        var vm = this.bunVM().jsc;
        this.processGCTimerWithHeapSize(vm, vm.blockBytesAllocated());
    }

    fn processGCTimerWithHeapSize(this: *GarbageCollectionController, vm: *JSC.VM, this_heap_size: usize) void {
        const prev = this.gc_last_heap_size;

        switch (this.gc_timer_state) {
            .run_on_next_tick => {
                // When memory usage is not stable, run the GC more.
                if (this_heap_size != prev) {
                    this.scheduleGCTimer();
                    this.updateGCRepeatTimer(.fast);
                } else {
                    this.gc_timer_state = .pending;
                }
                vm.collectAsync();
                this.gc_last_heap_size = this_heap_size;
            },
            .pending => {
                if (this_heap_size != prev) {
                    this.updateGCRepeatTimer(.fast);

                    if (this_heap_size > prev * 2) {
                        this.performGC();
                    } else {
                        this.scheduleGCTimer();
                    }
                }
            },
            .scheduled => {
                if (this_heap_size > prev * 2) {
                    this.updateGCRepeatTimer(.fast);
                    this.performGC();
                }
            },
        }
    }

    pub fn performGC(this: *GarbageCollectionController) void {
        if (this.disabled) return;
        var vm = this.bunVM().jsc;
        vm.collectAsync();
        this.gc_last_heap_size = vm.blockBytesAllocated();
    }

    pub const GCTimerState = enum {
        pending,
        scheduled,
        run_on_next_tick,
    };
};

export fn Bun__tickWhilePaused(paused: *bool) void {
    JSC.markBinding(@src());
    VirtualMachine.get().eventLoop().tickWhilePaused(paused);
}

comptime {
    _ = Bun__tickWhilePaused;
}

/// Sometimes, you have work that will be scheduled, cancelled, and rescheduled multiple times
/// The order of that work may not particularly matter.
///
/// An example of this is when writing to a file or network socket.
///
/// You want to balance:
///     1) Writing as much as possible to the file/socket in as few system calls as possible
///     2) Writing to the file/socket as soon as possible
///
/// That is a scheduling problem. How do you decide when to write to the file/socket? Developers
/// don't want to remember to call `flush` every time they write to a file/socket, but we don't
/// want them to have to think about buffering or not buffering either.
///
/// Our answer to this is the DeferredTaskQueue.
///
/// When you call write() when sending a streaming HTTP response, we don't actually write it immediately
/// by default. Instead, we wait until the end of the microtask queue to write it, unless either:
///
/// - The buffer is full
/// - The developer calls `flush` manually
///
/// But that means every time you call .write(), we have to check not only if the buffer is full, but also if
/// it previously had scheduled a write to the file/socket. So we use an ArrayHashMap to keep track of the
/// list of pointers which have a deferred task scheduled.
///
/// The DeferredTaskQueue is drained after the microtask queue, but before other tasks are executed. This avoids re-entrancy
/// issues with the event loop.
pub const DeferredTaskQueue = struct {
    pub const DeferredRepeatingTask = *const (fn (*anyopaque) bool);

    map: std.AutoArrayHashMapUnmanaged(?*anyopaque, DeferredRepeatingTask) = .{},

    pub fn postTask(this: *DeferredTaskQueue, ctx: ?*anyopaque, task: DeferredRepeatingTask) bool {
        const existing = this.map.getOrPutValue(bun.default_allocator, ctx, task) catch bun.outOfMemory();
        return existing.found_existing;
    }

    pub fn unregisterTask(this: *DeferredTaskQueue, ctx: ?*anyopaque) bool {
        return this.map.swapRemove(ctx);
    }

    pub fn run(this: *DeferredTaskQueue) void {
        var i: usize = 0;
        var last = this.map.count();
        while (i < last) {
            const key = this.map.keys()[i] orelse {
                this.map.swapRemoveAt(i);
                last = this.map.count();
                continue;
            };

            if (!this.map.values()[i](key)) {
                this.map.swapRemoveAt(i);
                last = this.map.count();
            } else {
                i += 1;
            }
        }
    }

    pub fn deinit(this: *DeferredTaskQueue) void {
        this.map.deinit(bun.default_allocator);
    }
};
pub const EventLoop = struct {
    tasks: Queue = undefined,

    /// setImmediate() gets it's own two task queues
    /// When you call `setImmediate` in JS, it queues to the start of the next tick
    /// This is confusing, but that is how it works in Node.js.
    ///
    /// So we have two queues:
    ///   - next_immediate_tasks: tasks that will run on the next tick
    ///   - immediate_tasks: tasks that will run on the current tick
    ///
    /// Having two queues avoids infinite loops creating by calling `setImmediate` in a `setImmediate` callback.
    immediate_tasks: std.ArrayListUnmanaged(*JSC.BunTimer.ImmediateObject) = .{},
    next_immediate_tasks: std.ArrayListUnmanaged(*JSC.BunTimer.ImmediateObject) = .{},

    concurrent_tasks: ConcurrentTask.Queue = ConcurrentTask.Queue{},
    global: *JSC.JSGlobalObject = undefined,
    virtual_machine: *VirtualMachine = undefined,
    waker: ?Waker = null,
    forever_timer: ?*uws.Timer = null,
    deferred_tasks: DeferredTaskQueue = .{},
    uws_loop: if (Environment.isWindows) ?*uws.Loop else void = if (Environment.isWindows) null,

    debug: Debug = .{},
    entered_event_loop_count: isize = 0,
    concurrent_ref: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    imminent_gc_timer: std.atomic.Value(?*JSC.BunTimer.WTFTimer) = .{ .raw = null },

    signal_handler: if (Environment.isPosix) ?*PosixSignalHandle else void = if (Environment.isPosix) null,

    pub export fn Bun__ensureSignalHandler() void {
        if (Environment.isPosix) {
            if (VirtualMachine.getMainThreadVM()) |vm| {
                const this = vm.eventLoop();
                if (this.signal_handler == null) {
                    this.signal_handler = PosixSignalHandle.new(.{});
                    @memset(&this.signal_handler.?.signals, 0);
                }
            }
        }
    }

    pub const Debug = if (Environment.isDebug) struct {
        is_inside_tick_queue: bool = false,
        js_call_count_outside_tick_queue: usize = 0,
        drain_microtasks_count_outside_tick_queue: usize = 0,
        _prev_is_inside_tick_queue: bool = false,
        last_fn_name: bun.String = bun.String.empty,
        track_last_fn_name: bool = false,

        pub fn enter(this: *Debug) void {
            this._prev_is_inside_tick_queue = this.is_inside_tick_queue;
            this.is_inside_tick_queue = true;
            this.js_call_count_outside_tick_queue = 0;
            this.drain_microtasks_count_outside_tick_queue = 0;
        }

        pub fn exit(this: *Debug) void {
            this.is_inside_tick_queue = this._prev_is_inside_tick_queue;
            this._prev_is_inside_tick_queue = false;
            this.js_call_count_outside_tick_queue = 0;
            this.drain_microtasks_count_outside_tick_queue = 0;
            this.last_fn_name.deref();
            this.last_fn_name = bun.String.empty;
        }
    } else struct {
        pub inline fn enter(_: Debug) void {}
        pub inline fn exit(_: Debug) void {}
    };

    pub fn enter(this: *EventLoop) void {
        log("enter() = {d}", .{this.entered_event_loop_count});
        this.entered_event_loop_count += 1;
        this.debug.enter();
    }

    pub fn exit(this: *EventLoop) void {
        const count = this.entered_event_loop_count;
        log("exit() = {d}", .{count - 1});

        defer this.debug.exit();

        if (count == 1 and !this.virtual_machine.is_inside_deferred_task_queue) {
            this.drainMicrotasksWithGlobal(this.global, this.virtual_machine.jsc);
        }

        this.entered_event_loop_count -= 1;
    }

    pub inline fn getVmImpl(this: *EventLoop) *VirtualMachine {
        return this.virtual_machine;
    }

    pub fn pipeReadBuffer(this: *const EventLoop) []u8 {
        return this.virtual_machine.rareData().pipeReadBuffer();
    }

    pub const Queue = std.fifo.LinearFifo(Task, .Dynamic);
    const log = bun.Output.scoped(.EventLoop, false);

    pub fn tickWhilePaused(this: *EventLoop, done: *bool) void {
        while (!done.*) {
            this.virtual_machine.event_loop_handle.?.tick();
        }
    }

    extern fn JSC__JSGlobalObject__drainMicrotasks(*JSC.JSGlobalObject) void;
    pub fn drainMicrotasksWithGlobal(this: *EventLoop, globalObject: *JSC.JSGlobalObject, jsc_vm: *JSC.VM) void {
        JSC.markBinding(@src());

        jsc_vm.releaseWeakRefs();
        JSC__JSGlobalObject__drainMicrotasks(globalObject);

        this.virtual_machine.is_inside_deferred_task_queue = true;
        this.deferred_tasks.run();
        this.virtual_machine.is_inside_deferred_task_queue = false;

        if (comptime bun.Environment.isDebug) {
            this.debug.drain_microtasks_count_outside_tick_queue += @as(usize, @intFromBool(!this.debug.is_inside_tick_queue));
        }
    }

    pub fn drainMicrotasks(this: *EventLoop) void {
        this.drainMicrotasksWithGlobal(this.global, this.virtual_machine.jsc);
    }

    /// When you call a JavaScript function from outside the event loop task
    /// queue
    ///
    /// It has to be wrapped in `runCallback` to ensure that microtasks are
    /// drained and errors are handled.
    ///
    /// Otherwise, you will risk a large number of microtasks being queued and
    /// not being drained, which can lead to catastrophic memory usage and
    /// application slowdown.
    pub fn runCallback(this: *EventLoop, callback: JSC.JSValue, globalObject: *JSC.JSGlobalObject, thisValue: JSC.JSValue, arguments: []const JSC.JSValue) void {
        this.enter();
        defer this.exit();
        _ = callback.call(globalObject, thisValue, arguments) catch |err|
            globalObject.reportActiveExceptionAsUnhandled(err);
    }

    fn externRunCallback1(global: *JSC.JSGlobalObject, callback: JSC.JSValue, thisValue: JSC.JSValue, arg0: JSC.JSValue) callconv(.c) void {
        const vm = global.bunVM();
        var loop = vm.eventLoop();
        loop.runCallback(callback, global, thisValue, &.{arg0});
    }

    fn externRunCallback2(global: *JSC.JSGlobalObject, callback: JSC.JSValue, thisValue: JSC.JSValue, arg0: JSC.JSValue, arg1: JSC.JSValue) callconv(.c) void {
        const vm = global.bunVM();
        var loop = vm.eventLoop();
        loop.runCallback(callback, global, thisValue, &.{ arg0, arg1 });
    }

    comptime {
        @export(&externRunCallback1, .{ .name = "Bun__EventLoop__runCallback1" });
        @export(&externRunCallback2, .{ .name = "Bun__EventLoop__runCallback2" });
    }

    pub fn runCallbackWithResult(this: *EventLoop, callback: JSC.JSValue, globalObject: *JSC.JSGlobalObject, thisValue: JSC.JSValue, arguments: []const JSC.JSValue) JSC.JSValue {
        this.enter();
        defer this.exit();

        const result = callback.call(globalObject, thisValue, arguments) catch |err| {
            globalObject.reportActiveExceptionAsUnhandled(err);
            return .zero;
        };
        return result;
    }

    fn tickQueueWithCount(this: *EventLoop, virtual_machine: *VirtualMachine, comptime queue_name: []const u8) u32 {
        var global = this.global;
        const global_vm = global.vm();
        var counter: usize = 0;

        if (comptime Environment.isDebug) {
            if (this.debug.js_call_count_outside_tick_queue > this.debug.drain_microtasks_count_outside_tick_queue) {
                if (this.debug.track_last_fn_name) {
                    bun.Output.panic(
                        \\<b>{d} JavaScript functions<r> were called outside of the microtask queue without draining microtasks.
                        \\
                        \\Last function name: {}
                        \\
                        \\Use EventLoop.runCallback() to run JavaScript functions outside of the microtask queue.
                        \\
                        \\Failing to do this can lead to a large number of microtasks being queued and not being drained, which can lead to a large amount of memory being used and application slowdown.
                    ,
                        .{
                            this.debug.js_call_count_outside_tick_queue - this.debug.drain_microtasks_count_outside_tick_queue,
                            this.debug.last_fn_name,
                        },
                    );
                } else {
                    bun.Output.panic(
                        \\<b>{d} JavaScript functions<r> were called outside of the microtask queue without draining microtasks. To track the last function name, set the BUN_TRACK_LAST_FN_NAME environment variable.
                        \\
                        \\Use EventLoop.runCallback() to run JavaScript functions outside of the microtask queue.
                        \\
                        \\Failing to do this can lead to a large number of microtasks being queued and not being drained, which can lead to a large amount of memory being used and application slowdown.
                    ,
                        .{this.debug.js_call_count_outside_tick_queue - this.debug.drain_microtasks_count_outside_tick_queue},
                    );
                }
            }
        }

        while (@field(this, queue_name).readItem()) |task| {
            log("run {s}", .{@tagName(task.tag())});
            defer counter += 1;
            switch (task.tag()) {
                @field(Task.Tag, @typeName(ShellAsync)) => {
                    var shell_ls_task: *ShellAsync = task.get(ShellAsync).?;
                    shell_ls_task.runFromMainThread();
                },
                @field(Task.Tag, @typeName(ShellAsyncSubprocessDone)) => {
                    var shell_ls_task: *ShellAsyncSubprocessDone = task.get(ShellAsyncSubprocessDone).?;
                    shell_ls_task.runFromMainThread();
                },
                @field(Task.Tag, @typeName(ShellIOWriterAsyncDeinit)) => {
                    var shell_ls_task: *ShellIOWriterAsyncDeinit = task.get(ShellIOWriterAsyncDeinit).?;
                    shell_ls_task.runFromMainThread();
                },
                @field(Task.Tag, @typeName(ShellIOReaderAsyncDeinit)) => {
                    var shell_ls_task: *ShellIOReaderAsyncDeinit = task.get(ShellIOReaderAsyncDeinit).?;
                    shell_ls_task.runFromMainThread();
                },
                @field(Task.Tag, @typeName(ShellCondExprStatTask)) => {
                    var shell_ls_task: *ShellCondExprStatTask = task.get(ShellCondExprStatTask).?;
                    shell_ls_task.task.runFromMainThread();
                },
                @field(Task.Tag, @typeName(ShellCpTask)) => {
                    var shell_ls_task: *ShellCpTask = task.get(ShellCpTask).?;
                    shell_ls_task.runFromMainThread();
                },
                @field(Task.Tag, @typeName(ShellTouchTask)) => {
                    var shell_ls_task: *ShellTouchTask = task.get(ShellTouchTask).?;
                    shell_ls_task.runFromMainThread();
                },
                @field(Task.Tag, @typeName(ShellMkdirTask)) => {
                    var shell_ls_task: *ShellMkdirTask = task.get(ShellMkdirTask).?;
                    shell_ls_task.runFromMainThread();
                },
                @field(Task.Tag, @typeName(ShellLsTask)) => {
                    var shell_ls_task: *ShellLsTask = task.get(ShellLsTask).?;
                    shell_ls_task.runFromMainThread();
                },
                @field(Task.Tag, @typeName(ShellMvBatchedTask)) => {
                    var shell_mv_batched_task: *ShellMvBatchedTask = task.get(ShellMvBatchedTask).?;
                    shell_mv_batched_task.task.runFromMainThread();
                },
                @field(Task.Tag, @typeName(ShellMvCheckTargetTask)) => {
                    var shell_mv_check_target_task: *ShellMvCheckTargetTask = task.get(ShellMvCheckTargetTask).?;
                    shell_mv_check_target_task.task.runFromMainThread();
                },
                @field(Task.Tag, @typeName(ShellRmTask)) => {
                    var shell_rm_task: *ShellRmTask = task.get(ShellRmTask).?;
                    shell_rm_task.runFromMainThread();
                },
                @field(Task.Tag, @typeName(ShellRmDirTask)) => {
                    var shell_rm_task: *ShellRmDirTask = task.get(ShellRmDirTask).?;
                    shell_rm_task.runFromMainThread();
                },
                @field(Task.Tag, @typeName(ShellGlobTask)) => {
                    var shell_glob_task: *ShellGlobTask = task.get(ShellGlobTask).?;
                    shell_glob_task.runFromMainThread();
                    shell_glob_task.deinit();
                },
                @field(Task.Tag, @typeName(FetchTasklet)) => {
                    var fetch_task: *Fetch.FetchTasklet = task.get(Fetch.FetchTasklet).?;
                    fetch_task.onProgressUpdate();
                },
                @field(Task.Tag, @typeName(S3HttpSimpleTask)) => {
                    var s3_task: *S3HttpSimpleTask = task.get(S3HttpSimpleTask).?;
                    s3_task.onResponse();
                },
                @field(Task.Tag, @typeName(S3HttpDownloadStreamingTask)) => {
                    var s3_task: *S3HttpDownloadStreamingTask = task.get(S3HttpDownloadStreamingTask).?;
                    s3_task.onResponse();
                },
                @field(Task.Tag, @typeName(AsyncGlobWalkTask)) => {
                    var globWalkTask: *AsyncGlobWalkTask = task.get(AsyncGlobWalkTask).?;
                    globWalkTask.*.runFromJS();
                    globWalkTask.deinit();
                },
                @field(Task.Tag, @typeName(AsyncTransformTask)) => {
                    var transform_task: *AsyncTransformTask = task.get(AsyncTransformTask).?;
                    transform_task.*.runFromJS();
                    transform_task.deinit();
                },
                @field(Task.Tag, @typeName(CopyFilePromiseTask)) => {
                    var transform_task: *CopyFilePromiseTask = task.get(CopyFilePromiseTask).?;
                    transform_task.*.runFromJS();
                    transform_task.deinit();
                },
                @field(Task.Tag, @typeName(JSC.napi.napi_async_work)) => {
                    const transform_task: *JSC.napi.napi_async_work = task.get(JSC.napi.napi_async_work).?;
                    transform_task.*.runFromJS();
                },
                @field(Task.Tag, @typeName(ThreadSafeFunction)) => {
                    var transform_task: *ThreadSafeFunction = task.as(ThreadSafeFunction);
                    transform_task.onDispatch();
                },
                @field(Task.Tag, @typeName(ReadFileTask)) => {
                    var transform_task: *ReadFileTask = task.get(ReadFileTask).?;
                    transform_task.*.runFromJS();
                    transform_task.deinit();
                },
                @field(Task.Tag, @typeName(JSCDeferredWorkTask)) => {
                    var jsc_task: *JSCDeferredWorkTask = task.get(JSCDeferredWorkTask).?;
                    JSC.markBinding(@src());
                    jsc_task.run();
                },
                @field(Task.Tag, @typeName(WriteFileTask)) => {
                    var transform_task: *WriteFileTask = task.get(WriteFileTask).?;
                    transform_task.*.runFromJS();
                    transform_task.deinit();
                },
                @field(Task.Tag, @typeName(HotReloadTask)) => {
                    const transform_task: *HotReloadTask = task.get(HotReloadTask).?;
                    transform_task.run();
                    transform_task.deinit();
                    // special case: we return
                    return 0;
                },
                @field(Task.Tag, @typeName(bun.bake.DevServer.HotReloadEvent)) => {
                    const hmr_task: *bun.bake.DevServer.HotReloadEvent = task.get(bun.bake.DevServer.HotReloadEvent).?;
                    hmr_task.run();
                },
                @field(Task.Tag, @typeName(FSWatchTask)) => {
                    var transform_task: *FSWatchTask = task.get(FSWatchTask).?;
                    transform_task.*.run();
                    transform_task.deinit();
                },
                @field(Task.Tag, @typeName(AnyTask)) => {
                    var any: *AnyTask = task.get(AnyTask).?;
                    any.run();
                },
                @field(Task.Tag, @typeName(ManagedTask)) => {
                    var any: *ManagedTask = task.get(ManagedTask).?;
                    any.run();
                },
                @field(Task.Tag, @typeName(CppTask)) => {
                    var any: *CppTask = task.get(CppTask).?;
                    any.run(global);
                },
                @field(Task.Tag, @typeName(PollPendingModulesTask)) => {
                    virtual_machine.modules.onPoll();
                },
                @field(Task.Tag, @typeName(GetAddrInfoRequestTask)) => {
                    if (Environment.os == .windows) @panic("This should not be reachable on Windows");

                    var any: *GetAddrInfoRequestTask = task.get(GetAddrInfoRequestTask).?;
                    any.runFromJS();
                    any.deinit();
                },
                @field(Task.Tag, @typeName(Stat)) => {
                    var any: *Stat = task.get(Stat).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(Lstat)) => {
                    var any: *Lstat = task.get(Lstat).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(Fstat)) => {
                    var any: *Fstat = task.get(Fstat).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(Open)) => {
                    var any: *Open = task.get(Open).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(ReadFile)) => {
                    var any: *ReadFile = task.get(ReadFile).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(WriteFile)) => {
                    var any: *WriteFile = task.get(WriteFile).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(CopyFile)) => {
                    var any: *CopyFile = task.get(CopyFile).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(Read)) => {
                    var any: *Read = task.get(Read).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(Write)) => {
                    var any: *Write = task.get(Write).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(Truncate)) => {
                    var any: *Truncate = task.get(Truncate).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(Writev)) => {
                    var any: *Writev = task.get(Writev).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(Readv)) => {
                    var any: *Readv = task.get(Readv).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(Rename)) => {
                    var any: *Rename = task.get(Rename).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(FTruncate)) => {
                    var any: *FTruncate = task.get(FTruncate).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(Readdir)) => {
                    var any: *Readdir = task.get(Readdir).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(ReaddirRecursive)) => {
                    var any: *ReaddirRecursive = task.get(ReaddirRecursive).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(Close)) => {
                    var any: *Close = task.get(Close).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(Rm)) => {
                    var any: *Rm = task.get(Rm).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(Rmdir)) => {
                    var any: *Rmdir = task.get(Rmdir).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(Chown)) => {
                    var any: *Chown = task.get(Chown).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(FChown)) => {
                    var any: *FChown = task.get(FChown).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(Utimes)) => {
                    var any: *Utimes = task.get(Utimes).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(Lutimes)) => {
                    var any: *Lutimes = task.get(Lutimes).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(Chmod)) => {
                    var any: *Chmod = task.get(Chmod).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(Fchmod)) => {
                    var any: *Fchmod = task.get(Fchmod).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(Link)) => {
                    var any: *Link = task.get(Link).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(Symlink)) => {
                    var any: *Symlink = task.get(Symlink).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(Readlink)) => {
                    var any: *Readlink = task.get(Readlink).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(Realpath)) => {
                    var any: *Realpath = task.get(Realpath).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(RealpathNonNative)) => {
                    var any: *RealpathNonNative = task.get(RealpathNonNative).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(Mkdir)) => {
                    var any: *Mkdir = task.get(Mkdir).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(Fsync)) => {
                    var any: *Fsync = task.get(Fsync).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(Fdatasync)) => {
                    var any: *Fdatasync = task.get(Fdatasync).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(Access)) => {
                    var any: *Access = task.get(Access).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(AppendFile)) => {
                    var any: *AppendFile = task.get(AppendFile).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(Mkdtemp)) => {
                    var any: *Mkdtemp = task.get(Mkdtemp).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(Exists)) => {
                    var any: *Exists = task.get(Exists).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(Futimes)) => {
                    var any: *Futimes = task.get(Futimes).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(Lchmod)) => {
                    var any: *Lchmod = task.get(Lchmod).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(Lchown)) => {
                    var any: *Lchown = task.get(Lchown).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(Unlink)) => {
                    var any: *Unlink = task.get(Unlink).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(NativeZlib)) => {
                    var any: *NativeZlib = task.get(NativeZlib).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(NativeBrotli)) => {
                    var any: *NativeBrotli = task.get(NativeBrotli).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(ProcessWaiterThreadTask)) => {
                    bun.markPosixOnly();
                    var any: *ProcessWaiterThreadTask = task.get(ProcessWaiterThreadTask).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(RuntimeTranspilerStore)) => {
                    var any: *RuntimeTranspilerStore = task.get(RuntimeTranspilerStore).?;
                    any.drain();
                },
                @field(Task.Tag, @typeName(TimeoutObject)) => {
                    var any: *TimeoutObject = task.get(TimeoutObject).?;
                    any.runImmediateTask(virtual_machine);
                },
                @field(Task.Tag, @typeName(ImmediateObject)) => {
                    var any: *ImmediateObject = task.get(ImmediateObject).?;
                    any.runImmediateTask(virtual_machine);
                },
                @field(Task.Tag, @typeName(ServerAllConnectionsClosedTask)) => {
                    var any: *ServerAllConnectionsClosedTask = task.get(ServerAllConnectionsClosedTask).?;
                    any.runFromJSThread(virtual_machine);
                },
                @field(Task.Tag, @typeName(bun.bundle_v2.DeferredBatchTask)) => {
                    var any: *bun.bundle_v2.DeferredBatchTask = task.get(bun.bundle_v2.DeferredBatchTask).?;
                    any.runOnJSThread();
                },
                @field(Task.Tag, @typeName(PosixSignalTask)) => {
                    PosixSignalTask.runFromJSThread(@intCast(task.asUintptr()), global);
                },
                @field(Task.Tag, @typeName(NapiFinalizerTask)) => {
                    task.get(NapiFinalizerTask).?.runOnJSThread();
                },
                @field(Task.Tag, @typeName(StatFS)) => {
                    var any: *StatFS = task.get(StatFS).?;
                    any.runFromJSThread();
                },
                @field(Task.Tag, @typeName(FlushPendingFileSinkTask)) => {
                    var any: *FlushPendingFileSinkTask = task.get(FlushPendingFileSinkTask).?;
                    any.runFromJSThread();
                },

                else => {
                    bun.Output.panic("Unexpected tag: {s}", .{@tagName(task.tag())});
                },
            }

            this.drainMicrotasksWithGlobal(global, global_vm);
        }

        @field(this, queue_name).head = if (@field(this, queue_name).count == 0) 0 else @field(this, queue_name).head;
        return @as(u32, @truncate(counter));
    }

    fn tickWithCount(this: *EventLoop, virtual_machine: *VirtualMachine) u32 {
        return this.tickQueueWithCount(virtual_machine, "tasks");
    }

    pub fn tickImmediateTasks(this: *EventLoop, virtual_machine: *VirtualMachine) void {
        var global = this.global;
        const global_vm = global.vm();

        var to_run_now = this.immediate_tasks;

        this.immediate_tasks = this.next_immediate_tasks;
        this.next_immediate_tasks = .{};

        for (to_run_now.items) |task| {
            task.runImmediateTask(virtual_machine);
            this.drainMicrotasksWithGlobal(global, global_vm);
        }

        if (this.next_immediate_tasks.capacity > 0) {
            // this would only occur if we were recursively running tickImmediateTasks.
            @branchHint(.unlikely);
            this.immediate_tasks.appendSlice(bun.default_allocator, this.next_immediate_tasks.items) catch bun.outOfMemory();
            this.next_immediate_tasks.deinit(bun.default_allocator);
        }

        if (to_run_now.capacity > 1024 * 128) {
            // once in a while, deinit the array to free up memory
            to_run_now.clearAndFree(bun.default_allocator);
        } else {
            to_run_now.clearRetainingCapacity();
        }

        this.next_immediate_tasks = to_run_now;
    }

    fn tickConcurrent(this: *EventLoop) void {
        _ = this.tickConcurrentWithCount();
    }

    /// Check whether refConcurrently has been called but the change has not yet been applied to the
    /// underlying event loop's `active` counter
    pub fn hasPendingRefs(this: *const EventLoop) bool {
        return this.concurrent_ref.load(.seq_cst) > 0;
    }

    fn updateCounts(this: *EventLoop) void {
        const delta = this.concurrent_ref.swap(0, .seq_cst);
        const loop = this.virtual_machine.event_loop_handle.?;
        if (comptime Environment.isWindows) {
            if (delta > 0) {
                loop.active_handles += @intCast(delta);
            } else {
                loop.active_handles -= @intCast(-delta);
            }
        } else {
            if (delta > 0) {
                loop.num_polls += @intCast(delta);
                loop.active += @intCast(delta);
            } else {
                loop.num_polls -= @intCast(-delta);
                loop.active -= @intCast(-delta);
            }
        }
    }

    pub fn runImminentGCTimer(this: *EventLoop) void {
        if (this.imminent_gc_timer.swap(null, .seq_cst)) |timer| {
            timer.run(this.virtual_machine);
        }
    }

    pub fn tickConcurrentWithCount(this: *EventLoop) usize {
        this.updateCounts();

        if (comptime Environment.isPosix) {
            if (this.signal_handler) |signal_handler| {
                signal_handler.drain(this);
            }
        }

        this.runImminentGCTimer();

        var concurrent = this.concurrent_tasks.popBatch();
        const count = concurrent.count;
        if (count == 0)
            return 0;

        var iter = concurrent.iterator();
        const start_count = this.tasks.count;
        if (start_count == 0) {
            this.tasks.head = 0;
        }

        this.tasks.ensureUnusedCapacity(count) catch unreachable;
        var writable = this.tasks.writableSlice(0);

        // Defer destruction of the ConcurrentTask to avoid issues with pointer aliasing
        var to_destroy: ?*ConcurrentTask = null;

        while (iter.next()) |task| {
            if (to_destroy) |dest| {
                to_destroy = null;
                dest.deinit();
            }

            if (task.auto_delete) {
                to_destroy = task;
            }

            writable[0] = task.task;
            writable = writable[1..];
            this.tasks.count += 1;
            if (writable.len == 0) break;
        }

        if (to_destroy) |dest| {
            dest.deinit();
        }

        return this.tasks.count - start_count;
    }

    inline fn usocketsLoop(this: *const EventLoop) *uws.Loop {
        if (comptime Environment.isWindows) {
            return this.uws_loop.?;
        }

        return this.virtual_machine.event_loop_handle.?;
    }

    pub fn autoTick(this: *EventLoop) void {
        var loop = this.usocketsLoop();
        var ctx = this.virtual_machine;

        this.tickImmediateTasks(ctx);
        if (comptime Environment.isPosix) {
            if (this.immediate_tasks.items.len > 0) {
                this.wakeup();
            }
        }

        if (comptime Environment.isPosix) {
            // Some tasks need to keep the event loop alive for one more tick.
            // We want to keep the event loop alive long enough to process those ticks and any microtasks
            //
            // BUT. We don't actually have an idle event in that case.
            // That means the process will be waiting forever on nothing.
            // So we need to drain the counter immediately before entering uSockets loop
            const pending_unref = ctx.pending_unref_counter;
            if (pending_unref > 0) {
                ctx.pending_unref_counter = 0;
                loop.unrefCount(pending_unref);
            }
        }

        this.runImminentGCTimer();

        if (loop.isActive()) {
            this.processGCTimer();
            var event_loop_sleep_timer = if (comptime Environment.isDebug) std.time.Timer.start() catch unreachable;
            // for the printer, this is defined:
            var timespec: bun.timespec = if (Environment.isDebug) .{ .sec = 0, .nsec = 0 } else undefined;
            loop.tickWithTimeout(if (ctx.timer.getTimeout(&timespec, ctx)) &timespec else null);

            if (comptime Environment.isDebug) {
                log("tick {}, timeout: {}", .{ std.fmt.fmtDuration(event_loop_sleep_timer.read()), std.fmt.fmtDuration(timespec.ns()) });
            }
        } else {
            loop.tickWithoutIdle();
            if (comptime Environment.isDebug) {
                log("tickWithoutIdle", .{});
            }
        }

        if (Environment.isPosix) {
            ctx.timer.drainTimers(ctx);
        }

        ctx.onAfterEventLoop();
        this.global.handleRejectedPromises();
    }

    pub fn tickPossiblyForever(this: *EventLoop) void {
        var ctx = this.virtual_machine;
        var loop = this.usocketsLoop();

        if (comptime Environment.isPosix) {
            const pending_unref = ctx.pending_unref_counter;
            if (pending_unref > 0) {
                ctx.pending_unref_counter = 0;
                loop.unrefCount(pending_unref);
            }
        }

        if (!loop.isActive()) {
            if (this.forever_timer == null) {
                var t = uws.Timer.create(loop, this);
                t.set(this, &noopForeverTimer, 1000 * 60 * 4, 1000 * 60 * 4);
                this.forever_timer = t;
            }
        }

        this.processGCTimer();
        this.processGCTimer();
        loop.tick();

        ctx.onAfterEventLoop();
        this.tickConcurrent();
        this.tick();
    }

    fn noopForeverTimer(_: *uws.Timer) callconv(.C) void {
        // do nothing
    }

    pub fn autoTickActive(this: *EventLoop) void {
        var loop = this.usocketsLoop();
        var ctx = this.virtual_machine;

        this.tickImmediateTasks(ctx);
        if (comptime Environment.isPosix) {
            if (this.immediate_tasks.items.len > 0) {
                this.wakeup();
            }
        }

        if (comptime Environment.isPosix) {
            const pending_unref = ctx.pending_unref_counter;
            if (pending_unref > 0) {
                ctx.pending_unref_counter = 0;
                loop.unrefCount(pending_unref);
            }
        }

        if (loop.isActive()) {
            this.processGCTimer();
            var timespec: bun.timespec = undefined;

            loop.tickWithTimeout(if (ctx.timer.getTimeout(&timespec, ctx)) &timespec else null);
        } else {
            loop.tickWithoutIdle();
        }

        if (Environment.isPosix) {
            ctx.timer.drainTimers(ctx);
        }

        ctx.onAfterEventLoop();
    }

    pub fn processGCTimer(this: *EventLoop) void {
        this.virtual_machine.gc_controller.processGCTimer();
    }

    pub fn tick(this: *EventLoop) void {
        JSC.markBinding(@src());
        this.entered_event_loop_count += 1;
        this.debug.enter();
        defer {
            this.entered_event_loop_count -= 1;
            this.debug.exit();
        }

        const ctx = this.virtual_machine;
        this.tickConcurrent();
        this.processGCTimer();

        const global = ctx.global;
        const global_vm = ctx.jsc;

        while (true) {
            while (this.tickWithCount(ctx) > 0) : (this.global.handleRejectedPromises()) {
                this.tickConcurrent();
            } else {
                this.drainMicrotasksWithGlobal(global, global_vm);
                this.tickConcurrent();
                if (this.tasks.count > 0) continue;
            }
            break;
        }

        while (this.tickWithCount(ctx) > 0) {
            this.tickConcurrent();
        }

        this.global.handleRejectedPromises();
    }

    pub fn waitForPromise(this: *EventLoop, promise: JSC.AnyPromise) void {
        const jsc_vm = this.virtual_machine.jsc;
        switch (promise.status(jsc_vm)) {
            .pending => {
                while (promise.status(jsc_vm) == .pending) {
                    this.tick();

                    if (promise.status(jsc_vm) == .pending) {
                        this.autoTick();
                    }
                }
            },
            else => {},
        }
    }

    pub fn waitForPromiseWithTermination(this: *EventLoop, promise: JSC.AnyPromise) void {
        const worker = this.virtual_machine.worker orelse @panic("EventLoop.waitForPromiseWithTermination: worker is not initialized");
        const jsc_vm = this.virtual_machine.jsc;
        switch (promise.status(jsc_vm)) {
            .pending => {
                while (!worker.hasRequestedTerminate() and promise.status(jsc_vm) == .pending) {
                    this.tick();

                    if (!worker.hasRequestedTerminate() and promise.status(jsc_vm) == .pending) {
                        this.autoTick();
                    }
                }
            },
            else => {},
        }
    }

    pub fn enqueueTask(this: *EventLoop, task: Task) void {
        this.tasks.writeItem(task) catch unreachable;
    }

    pub fn enqueueImmediateTask(this: *EventLoop, task: *JSC.BunTimer.ImmediateObject) void {
        this.immediate_tasks.append(bun.default_allocator, task) catch bun.outOfMemory();
    }

    pub fn enqueueTaskWithTimeout(this: *EventLoop, task: Task, timeout: i32) void {
        // TODO: make this more efficient!
        const loop = this.virtual_machine.uwsLoop();
        var timer = uws.Timer.createFallthrough(loop, task.ptr());
        timer.set(task.ptr(), callTask, timeout, 0);
    }

    pub fn callTask(timer: *uws.Timer) callconv(.C) void {
        const task = Task.from(timer.as(*anyopaque));
        defer timer.deinit(true);

        VirtualMachine.get().enqueueTask(task);
    }

    pub fn ensureWaker(this: *EventLoop) void {
        JSC.markBinding(@src());
        if (this.virtual_machine.event_loop_handle == null) {
            if (comptime Environment.isWindows) {
                this.uws_loop = bun.uws.Loop.get();
                this.virtual_machine.event_loop_handle = Async.Loop.get();
            } else {
                this.virtual_machine.event_loop_handle = bun.Async.Loop.get();
            }

            this.virtual_machine.gc_controller.init(this.virtual_machine);
            // _ = actual.addPostHandler(*JSC.EventLoop, this, JSC.EventLoop.afterUSocketsTick);
            // _ = actual.addPreHandler(*JSC.VM, this.virtual_machine.jsc, JSC.VM.drainMicrotasks);
        }
        bun.uws.Loop.get().internal_loop_data.setParentEventLoop(bun.JSC.EventLoopHandle.init(this));
    }

    /// Asynchronously run the garbage collector and track how much memory is now allocated
    pub fn performGC(this: *EventLoop) void {
        this.virtual_machine.gc_controller.performGC();
    }

    pub fn wakeup(this: *EventLoop) void {
        if (comptime Environment.isWindows) {
            if (this.uws_loop) |loop| {
                loop.wakeup();
            }
            return;
        }

        if (this.virtual_machine.event_loop_handle) |loop| {
            loop.wakeup();
        }
    }
    pub fn enqueueTaskConcurrent(this: *EventLoop, task: *ConcurrentTask) void {
        if (comptime Environment.allow_assert) {
            if (this.virtual_machine.has_terminated) {
                @panic("EventLoop.enqueueTaskConcurrent: VM has terminated");
            }
        }

        if (comptime Environment.isDebug) {
            log("enqueueTaskConcurrent({s})", .{task.task.typeName() orelse "[unknown]"});
        }

        this.concurrent_tasks.push(task);
        this.wakeup();
    }

    pub fn enqueueTaskConcurrentBatch(this: *EventLoop, batch: ConcurrentTask.Queue.Batch) void {
        if (comptime Environment.allow_assert) {
            if (this.virtual_machine.has_terminated) {
                @panic("EventLoop.enqueueTaskConcurrent: VM has terminated");
            }
        }

        if (comptime Environment.isDebug) {
            log("enqueueTaskConcurrentBatch({d})", .{batch.count});
        }

        this.concurrent_tasks.pushBatch(batch.front.?, batch.last.?, batch.count);
        this.wakeup();
    }

    pub fn refConcurrently(this: *EventLoop) void {
        _ = this.concurrent_ref.fetchAdd(1, .seq_cst);
        this.wakeup();
    }

    pub fn unrefConcurrently(this: *EventLoop) void {
        // TODO maybe this should be AcquireRelease
        _ = this.concurrent_ref.fetchSub(1, .seq_cst);
        this.wakeup();
    }
};

pub const JsVM = struct {
    vm: *VirtualMachine,

    pub inline fn init(inner: *VirtualMachine) JsVM {
        return .{
            .vm = inner,
        };
    }

    pub inline fn loop(this: @This()) *JSC.EventLoop {
        return this.vm.event_loop;
    }

    pub inline fn allocFilePoll(this: @This()) *bun.Async.FilePoll {
        return this.vm.rareData().filePolls(this.vm).get();
    }

    pub inline fn platformEventLoop(this: @This()) *JSC.PlatformEventLoop {
        return this.vm.event_loop_handle.?;
    }

    pub inline fn incrementPendingUnrefCounter(this: @This()) void {
        this.vm.pending_unref_counter +|= 1;
    }

    pub inline fn filePolls(this: @This()) *Async.FilePoll.Store {
        return this.vm.rareData().filePolls(this.vm);
    }
};

pub const MiniVM = struct {
    mini: *JSC.MiniEventLoop,

    pub fn init(inner: *JSC.MiniEventLoop) MiniVM {
        return .{
            .mini = inner,
        };
    }

    pub inline fn loop(this: @This()) *JSC.MiniEventLoop {
        return this.mini;
    }

    pub inline fn allocFilePoll(this: @This()) *bun.Async.FilePoll {
        return this.mini.filePolls().get();
    }

    pub inline fn platformEventLoop(this: @This()) *JSC.PlatformEventLoop {
        if (comptime Environment.isWindows) {
            return this.mini.loop.uv_loop;
        }
        return this.mini.loop;
    }

    pub inline fn incrementPendingUnrefCounter(this: @This()) void {
        _ = this;
        @panic("FIXME TODO");
    }

    pub inline fn filePolls(this: @This()) *Async.FilePoll.Store {
        return this.mini.filePolls();
    }
};

pub const EventLoopKind = enum {
    js,
    mini,

    pub fn Type(comptime this: EventLoopKind) type {
        return switch (this) {
            .js => EventLoop,
            .mini => MiniEventLoop,
        };
    }

    pub fn refType(comptime this: EventLoopKind) type {
        return switch (this) {
            .js => *VirtualMachine,
            .mini => *JSC.MiniEventLoop,
        };
    }

    pub fn getVm(comptime this: EventLoopKind) EventLoopKind.refType(this) {
        return switch (this) {
            .js => VirtualMachine.get(),
            .mini => JSC.MiniEventLoop.global,
        };
    }
};

pub fn AbstractVM(inner: anytype) switch (@TypeOf(inner)) {
    *VirtualMachine => JsVM,
    *JSC.MiniEventLoop => MiniVM,
    else => @compileError("Invalid event loop ctx: " ++ @typeName(@TypeOf(inner))),
} {
    if (comptime @TypeOf(inner) == *VirtualMachine) return JsVM.init(inner);
    if (comptime @TypeOf(inner) == *JSC.MiniEventLoop) return MiniVM.init(inner);
    @compileError("Invalid event loop ctx: " ++ @typeName(@TypeOf(inner)));
}

// pub const EventLoopRefImpl = struct {
//     fn enqueueTask(ref: anytype) {
//         const event_loop_ctx =
//     }
// };

pub const MiniEventLoop = struct {
    tasks: Queue,
    concurrent_tasks: ConcurrentTaskQueue = .{},
    loop: *uws.Loop,
    allocator: std.mem.Allocator,
    file_polls_: ?*Async.FilePoll.Store = null,
    env: ?*bun.DotEnv.Loader = null,
    top_level_dir: []const u8 = "",
    after_event_loop_callback_ctx: ?*anyopaque = null,
    after_event_loop_callback: ?JSC.OpaqueCallback = null,
    pipe_read_buffer: ?*PipeReadBuffer = null,
    stdout_store: ?*bun.JSC.WebCore.Blob.Store = null,
    stderr_store: ?*bun.JSC.WebCore.Blob.Store = null,
    const PipeReadBuffer = [256 * 1024]u8;

    pub threadlocal var globalInitialized: bool = false;
    pub threadlocal var global: *MiniEventLoop = undefined;

    pub const ConcurrentTaskQueue = UnboundedQueue(AnyTaskWithExtraContext, .next);

    pub fn initGlobal(env: ?*bun.DotEnv.Loader) *MiniEventLoop {
        if (globalInitialized) return global;
        const loop = MiniEventLoop.init(bun.default_allocator);
        global = bun.default_allocator.create(MiniEventLoop) catch bun.outOfMemory();
        global.* = loop;
        global.loop.internal_loop_data.setParentEventLoop(bun.JSC.EventLoopHandle.init(global));
        global.env = env orelse bun.DotEnv.instance orelse env_loader: {
            const map = bun.default_allocator.create(bun.DotEnv.Map) catch bun.outOfMemory();
            map.* = bun.DotEnv.Map.init(bun.default_allocator);

            const loader = bun.default_allocator.create(bun.DotEnv.Loader) catch bun.outOfMemory();
            loader.* = bun.DotEnv.Loader.init(map, bun.default_allocator);
            break :env_loader loader;
        };
        globalInitialized = true;
        return global;
    }

    const Queue = std.fifo.LinearFifo(*AnyTaskWithExtraContext, .Dynamic);

    pub const Task = AnyTaskWithExtraContext;

    pub inline fn getVmImpl(this: *MiniEventLoop) *MiniEventLoop {
        return this;
    }

    pub fn throwError(_: *MiniEventLoop, err: bun.sys.Error) void {
        bun.Output.prettyErrorln("{}", .{err});
        bun.Output.flush();
    }

    pub fn pipeReadBuffer(this: *MiniEventLoop) []u8 {
        return this.pipe_read_buffer orelse {
            this.pipe_read_buffer = this.allocator.create(PipeReadBuffer) catch bun.outOfMemory();
            return this.pipe_read_buffer.?;
        };
    }

    pub fn onAfterEventLoop(this: *MiniEventLoop) void {
        if (this.after_event_loop_callback) |cb| {
            const ctx = this.after_event_loop_callback_ctx;
            this.after_event_loop_callback = null;
            this.after_event_loop_callback_ctx = null;
            cb(ctx);
        }
    }

    pub fn filePolls(this: *MiniEventLoop) *Async.FilePoll.Store {
        return this.file_polls_ orelse {
            this.file_polls_ = this.allocator.create(Async.FilePoll.Store) catch bun.outOfMemory();
            this.file_polls_.?.* = Async.FilePoll.Store.init();
            return this.file_polls_.?;
        };
    }

    pub fn init(
        allocator: std.mem.Allocator,
    ) MiniEventLoop {
        return .{
            .tasks = Queue.init(allocator),
            .allocator = allocator,
            .loop = uws.Loop.get(),
        };
    }

    pub fn deinit(this: *MiniEventLoop) void {
        this.tasks.deinit();
        bun.assert(this.concurrent_tasks.isEmpty());
    }

    pub fn tickConcurrentWithCount(this: *MiniEventLoop) usize {
        var concurrent = this.concurrent_tasks.popBatch();
        const count = concurrent.count;
        if (count == 0)
            return 0;

        var iter = concurrent.iterator();
        const start_count = this.tasks.count;
        if (start_count == 0) {
            this.tasks.head = 0;
        }

        this.tasks.ensureUnusedCapacity(count) catch unreachable;
        var writable = this.tasks.writableSlice(0);
        while (iter.next()) |task| {
            writable[0] = task;
            writable = writable[1..];
            this.tasks.count += 1;
            if (writable.len == 0) break;
        }

        return this.tasks.count - start_count;
    }

    pub fn tickOnce(
        this: *MiniEventLoop,
        context: *anyopaque,
    ) void {
        if (this.tickConcurrentWithCount() == 0 and this.tasks.count == 0) {
            defer this.onAfterEventLoop();
            this.loop.inc();
            this.loop.tick();
            this.loop.dec();
        }

        while (this.tasks.readItem()) |task| {
            task.run(context);
        }
    }

    pub fn tickWithoutIdle(
        this: *MiniEventLoop,
        context: *anyopaque,
    ) void {
        defer this.onAfterEventLoop();

        while (true) {
            _ = this.tickConcurrentWithCount();
            while (this.tasks.readItem()) |task| {
                task.run(context);
            }

            this.loop.tickWithoutIdle();

            if (this.tasks.count == 0 and this.tickConcurrentWithCount() == 0) break;
        }
    }

    pub fn tick(
        this: *MiniEventLoop,
        context: *anyopaque,
        comptime isDone: *const fn (*anyopaque) bool,
    ) void {
        while (!isDone(context)) {
            if (this.tickConcurrentWithCount() == 0 and this.tasks.count == 0) {
                defer this.onAfterEventLoop();
                this.loop.inc();
                this.loop.tick();
                this.loop.dec();
            }

            while (this.tasks.readItem()) |task| {
                task.run(context);
            }
        }
    }

    pub fn enqueueTask(
        this: *MiniEventLoop,
        comptime Context: type,
        ctx: *Context,
        comptime Callback: fn (*Context) void,
        comptime field: std.meta.FieldEnum(Context),
    ) void {
        const TaskType = MiniEventLoop.Task.New(Context, Callback);
        @field(ctx, @tagName(field)) = TaskType.init(ctx);
        this.enqueueJSCTask(&@field(ctx, @tagName(field)));
    }

    pub fn enqueueTaskConcurrent(this: *MiniEventLoop, task: *AnyTaskWithExtraContext) void {
        this.concurrent_tasks.push(task);
        this.loop.wakeup();
    }

    pub fn enqueueTaskConcurrentWithExtraCtx(
        this: *MiniEventLoop,
        comptime Context: type,
        comptime ParentContext: type,
        ctx: *Context,
        comptime Callback: fn (*Context, *ParentContext) void,
        comptime field: std.meta.FieldEnum(Context),
    ) void {
        JSC.markBinding(@src());
        const TaskType = MiniEventLoop.Task.New(Context, ParentContext, Callback);
        @field(ctx, @tagName(field)) = TaskType.init(ctx);

        this.concurrent_tasks.push(&@field(ctx, @tagName(field)));

        this.loop.wakeup();
    }

    pub fn stderr(this: *MiniEventLoop) *JSC.WebCore.Blob.Store {
        return this.stderr_store orelse brk: {
            var mode: bun.Mode = 0;
            const fd = if (Environment.isWindows) bun.FDImpl.fromUV(2).encode() else bun.STDERR_FD;

            switch (bun.sys.fstat(fd)) {
                .result => |stat| {
                    mode = @intCast(stat.mode);
                },
                .err => {},
            }

            const store = JSC.WebCore.Blob.Store.new(.{
                .ref_count = std.atomic.Value(u32).init(2),
                .allocator = bun.default_allocator,
                .data = .{
                    .file = JSC.WebCore.Blob.FileStore{
                        .pathlike = .{
                            .fd = fd,
                        },
                        .is_atty = bun.Output.stderr_descriptor_type == .terminal,
                        .mode = mode,
                    },
                },
            });

            this.stderr_store = store;
            break :brk store;
        };
    }

    pub fn stdout(this: *MiniEventLoop) *JSC.WebCore.Blob.Store {
        return this.stdout_store orelse brk: {
            var mode: bun.Mode = 0;
            const fd = if (Environment.isWindows) bun.FDImpl.fromUV(1).encode() else bun.STDOUT_FD;

            switch (bun.sys.fstat(fd)) {
                .result => |stat| {
                    mode = @intCast(stat.mode);
                },
                .err => {},
            }

            const store = JSC.WebCore.Blob.Store.new(.{
                .ref_count = std.atomic.Value(u32).init(2),
                .allocator = bun.default_allocator,
                .data = .{
                    .file = JSC.WebCore.Blob.FileStore{
                        .pathlike = .{
                            .fd = fd,
                        },
                        .is_atty = bun.Output.stdout_descriptor_type == .terminal,
                        .mode = mode,
                    },
                },
            });

            this.stdout_store = store;
            break :brk store;
        };
    }
};

pub const AnyEventLoop = union(enum) {
    js: *EventLoop,
    mini: MiniEventLoop,

    pub const Task = AnyTaskWithExtraContext;

    pub fn iterationNumber(this: *const AnyEventLoop) u64 {
        return switch (this.*) {
            .js => this.js.usocketsLoop().iterationNumber(),
            .mini => this.mini.loop.iterationNumber(),
        };
    }

    pub fn wakeup(this: *AnyEventLoop) void {
        this.loop().wakeup();
    }

    pub fn filePolls(this: *AnyEventLoop) *bun.Async.FilePoll.Store {
        return switch (this.*) {
            .js => this.js.virtual_machine.rareData().filePolls(this.js.virtual_machine),
            .mini => this.mini.filePolls(),
        };
    }

    pub fn putFilePoll(this: *AnyEventLoop, poll: *Async.FilePoll) void {
        switch (this.*) {
            .js => this.js.virtual_machine.rareData().filePolls(this.js.virtual_machine).put(poll, this.js.virtual_machine, poll.flags.contains(.was_ever_registered)),
            .mini => this.mini.filePolls().put(poll, &this.mini, poll.flags.contains(.was_ever_registered)),
        }
    }

    pub fn loop(this: *AnyEventLoop) *uws.Loop {
        return switch (this.*) {
            .js => this.js.virtual_machine.uwsLoop(),
            .mini => this.mini.loop,
        };
    }

    pub fn pipeReadBuffer(this: *AnyEventLoop) []u8 {
        return switch (this.*) {
            .js => this.js.pipeReadBuffer(),
            .mini => this.mini.pipeReadBuffer(),
        };
    }

    pub fn init(
        allocator: std.mem.Allocator,
    ) AnyEventLoop {
        return .{ .mini = MiniEventLoop.init(allocator) };
    }

    pub fn tick(
        this: *AnyEventLoop,
        context: anytype,
        comptime isDone: *const fn (@TypeOf(context)) bool,
    ) void {
        switch (this.*) {
            .js => {
                while (!isDone(context)) {
                    this.js.tick();
                    this.js.autoTick();
                }
            },
            .mini => {
                this.mini.tick(context, @ptrCast(isDone));
            },
        }
    }

    pub fn tickOnce(
        this: *AnyEventLoop,
        context: anytype,
    ) void {
        switch (this.*) {
            .js => {
                this.js.tick();
                this.js.autoTickActive();
            },
            .mini => {
                this.mini.tickWithoutIdle(context);
            },
        }
    }

    pub fn enqueueTaskConcurrent(
        this: *AnyEventLoop,
        comptime Context: type,
        comptime ParentContext: type,
        ctx: *Context,
        comptime Callback: fn (*Context, *ParentContext) void,
        comptime field: std.meta.FieldEnum(Context),
    ) void {
        switch (this.*) {
            .js => {
                bun.todoPanic(@src(), "AnyEventLoop.enqueueTaskConcurrent", .{});
                // const TaskType = AnyTask.New(Context, Callback);
                // @field(ctx, field) = TaskType.init(ctx);
                // var concurrent = bun.default_allocator.create(ConcurrentTask) catch unreachable;
                // _ = concurrent.from(JSC.Task.init(&@field(ctx, field)));
                // concurrent.auto_delete = true;
                // this.virtual_machine.jsc.enqueueTaskConcurrent(concurrent);
            },
            .mini => {
                this.mini.enqueueTaskConcurrentWithExtraCtx(Context, ParentContext, ctx, Callback, field);
            },
        }
    }
};

pub const EventLoopHandle = union(enum) {
    js: *JSC.EventLoop,
    mini: *MiniEventLoop,

    pub fn globalObject(this: EventLoopHandle) ?*JSC.JSGlobalObject {
        return switch (this) {
            .js => this.js.global,
            .mini => null,
        };
    }

    pub fn stdout(this: EventLoopHandle) *JSC.WebCore.Blob.Store {
        return switch (this) {
            .js => this.js.virtual_machine.rareData().stdout(),
            .mini => this.mini.stdout(),
        };
    }

    pub fn bunVM(this: EventLoopHandle) ?*VirtualMachine {
        if (this == .js) {
            return this.js.virtual_machine;
        }

        return null;
    }

    pub fn stderr(this: EventLoopHandle) *JSC.WebCore.Blob.Store {
        return switch (this) {
            .js => this.js.virtual_machine.rareData().stderr(),
            .mini => this.mini.stderr(),
        };
    }

    pub fn cast(this: EventLoopHandle, comptime as: @Type(.enum_literal)) if (as == .js) *JSC.EventLoop else *MiniEventLoop {
        if (as == .js) {
            if (this != .js) @panic("Expected *JSC.EventLoop but got *MiniEventLoop");
            return this.js;
        }

        if (as == .mini) {
            if (this != .mini) @panic("Expected *MiniEventLoop but got *JSC.EventLoop");
            return this.js;
        }

        @compileError("Invalid event loop kind " ++ @typeName(as));
    }

    pub fn enter(this: EventLoopHandle) void {
        switch (this) {
            .js => this.js.enter(),
            .mini => {},
        }
    }

    pub fn exit(this: EventLoopHandle) void {
        switch (this) {
            .js => this.js.exit(),
            .mini => {},
        }
    }

    pub fn init(context: anytype) EventLoopHandle {
        const Context = @TypeOf(context);
        return switch (Context) {
            *VirtualMachine => .{ .js = context.eventLoop() },
            *JSC.EventLoop => .{ .js = context },
            *JSC.MiniEventLoop => .{ .mini = context },
            *AnyEventLoop => switch (context.*) {
                .js => .{ .js = context.js },
                .mini => .{ .mini = &context.mini },
            },
            EventLoopHandle => context,
            else => @compileError("Invalid context type for EventLoopHandle.init " ++ @typeName(Context)),
        };
    }

    pub fn filePolls(this: EventLoopHandle) *bun.Async.FilePoll.Store {
        return switch (this) {
            .js => this.js.virtual_machine.rareData().filePolls(this.js.virtual_machine),
            .mini => this.mini.filePolls(),
        };
    }

    pub fn putFilePoll(this: *EventLoopHandle, poll: *Async.FilePoll) void {
        switch (this.*) {
            .js => this.js.virtual_machine.rareData().filePolls(this.js.virtual_machine).put(poll, this.js.virtual_machine, poll.flags.contains(.was_ever_registered)),
            .mini => this.mini.filePolls().put(poll, &this.mini, poll.flags.contains(.was_ever_registered)),
        }
    }

    pub fn enqueueTaskConcurrent(this: EventLoopHandle, context: EventLoopTaskPtr) void {
        switch (this) {
            .js => {
                this.js.enqueueTaskConcurrent(context.js);
            },
            .mini => {
                this.mini.enqueueTaskConcurrent(context.mini);
            },
        }
    }

    pub fn loop(this: EventLoopHandle) *bun.uws.Loop {
        return switch (this) {
            .js => this.js.usocketsLoop(),
            .mini => this.mini.loop,
        };
    }

    pub fn pipeReadBuffer(this: EventLoopHandle) []u8 {
        return switch (this) {
            .js => this.js.pipeReadBuffer(),
            .mini => this.mini.pipeReadBuffer(),
        };
    }

    pub const platformEventLoop = loop;

    pub fn ref(this: EventLoopHandle) void {
        this.loop().ref();
    }

    pub fn unref(this: EventLoopHandle) void {
        this.loop().unref();
    }

    pub inline fn createNullDelimitedEnvMap(this: @This(), alloc: Allocator) ![:null]?[*:0]const u8 {
        return switch (this) {
            .js => this.js.virtual_machine.transpiler.env.map.createNullDelimitedEnvMap(alloc),
            .mini => this.mini.env.?.map.createNullDelimitedEnvMap(alloc),
        };
    }

    pub inline fn allocator(this: EventLoopHandle) Allocator {
        return switch (this) {
            .js => this.js.virtual_machine.allocator,
            .mini => this.mini.allocator,
        };
    }

    pub inline fn topLevelDir(this: EventLoopHandle) []const u8 {
        return switch (this) {
            .js => this.js.virtual_machine.transpiler.fs.top_level_dir,
            .mini => this.mini.top_level_dir,
        };
    }

    pub inline fn env(this: EventLoopHandle) *bun.DotEnv.Loader {
        return switch (this) {
            .js => this.js.virtual_machine.transpiler.env,
            .mini => this.mini.env.?,
        };
    }
};

pub const EventLoopTask = union {
    js: ConcurrentTask,
    mini: JSC.AnyTaskWithExtraContext,

    pub fn init(comptime kind: @TypeOf(.enum_literal)) EventLoopTask {
        switch (kind) {
            .js => return .{ .js = ConcurrentTask{} },
            .mini => return .{ .mini = JSC.AnyTaskWithExtraContext{} },
            else => @compileError("Invalid kind: " ++ @typeName(kind)),
        }
    }

    pub fn fromEventLoop(loop: JSC.EventLoopHandle) EventLoopTask {
        switch (loop) {
            .js => return .{ .js = ConcurrentTask{} },
            .mini => return .{ .mini = JSC.AnyTaskWithExtraContext{} },
        }
    }
};

pub const EventLoopTaskPtr = union {
    js: *ConcurrentTask,
    mini: *JSC.AnyTaskWithExtraContext,
};

pub const PosixSignalHandle = struct {
    const buffer_size = 8192;

    signals: [buffer_size]u8 = undefined,

    // Producer index (signal handler writes).
    tail: std.atomic.Value(u16) = std.atomic.Value(u16).init(0),
    // Consumer index (main thread reads).
    head: std.atomic.Value(u16) = std.atomic.Value(u16).init(0),

    const log = bun.Output.scoped(.PosixSignalHandle, true);

    pub const new = bun.TrivialNew(@This());

    /// Called by the signal handler (single producer).
    /// Returns `true` if enqueued successfully, or `false` if the ring is full.
    pub fn enqueue(this: *PosixSignalHandle, signal: u8) bool {
        // Read the current tail and head (Acquire to ensure we have up‐to‐date values).
        const old_tail = this.tail.load(.acquire);
        const head_val = this.head.load(.acquire);

        // Compute the next tail (wrapping around buffer_size).
        const next_tail = (old_tail +% 1) % buffer_size;

        // Check if the ring is full.
        if (next_tail == (head_val % buffer_size)) {
            // The ring buffer is full.
            // We cannot block or wait here (since we're in a signal handler).
            // So we just drop the signal or log if desired.
            log("signal queue is full; dropping", .{});
            return false;
        }

        // Store the signal into the ring buffer slot (Release to ensure data is visible).
        @atomicStore(u8, &this.signals[old_tail % buffer_size], signal, .release);

        // Publish the new tail (Release so that the consumer sees the updated tail).
        this.tail.store(old_tail +% 1, .release);

        VirtualMachine.getMainThreadVM().?.eventLoop().wakeup();

        return true;
    }

    /// This is the signal handler entry point. Calls enqueue on the ring buffer.
    /// Note: Must be minimal logic here. Only do atomics & signal‐safe calls.
    export fn Bun__onPosixSignal(number: i32) void {
        const vm = VirtualMachine.getMainThreadVM().?;
        _ = vm.eventLoop().signal_handler.?.enqueue(@intCast(number));
    }

    /// Called by the main thread (single consumer).
    /// Returns `null` if the ring is empty, or the next signal otherwise.
    pub fn dequeue(this: *PosixSignalHandle) ?u8 {
        // Read the current head and tail.
        const old_head = this.head.load(.acquire);
        const tail_val = this.tail.load(.acquire);

        // If head == tail, the ring is empty.
        if (old_head == tail_val) {
            return null; // No available items
        }

        const slot_index = old_head % buffer_size;
        // Acquire load of the stored signal to get the item.
        const signal = @atomicRmw(u8, &this.signals[slot_index], .Xchg, 0, .acq_rel);

        // Publish the updated head (Release).
        this.head.store(old_head +% 1, .release);

        return signal;
    }

    /// Drain as many signals as possible and enqueue them as tasks in the event loop.
    /// Called by the main thread.
    pub fn drain(this: *PosixSignalHandle, event_loop: *JSC.EventLoop) void {
        while (this.dequeue()) |signal| {
            // Example: wrap the signal into a Task structure
            var posix_signal_task: PosixSignalTask = undefined;
            var task = JSC.Task.init(&posix_signal_task);
            task.setUintptr(signal);
            event_loop.enqueueTask(task);
        }
    }
};

pub const PosixSignalTask = struct {
    number: u8,
    extern "c" fn Bun__onSignalForJS(number: i32, globalObject: *JSC.JSGlobalObject) void;

    pub const new = bun.TrivialNew(@This());
    pub fn runFromJSThread(number: u8, globalObject: *JSC.JSGlobalObject) void {
        Bun__onSignalForJS(number, globalObject);
    }
};
