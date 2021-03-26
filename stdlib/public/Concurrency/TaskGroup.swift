//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Swift
@_implementationOnly import _SwiftConcurrencyShims

// ==== TaskGroup --------------------------------------------------------------

/// Starts a new task group which provides a scope in which a dynamic number of
/// tasks may be spawned.
///
/// Tasks added to the group by `group.spawn()` will automatically be awaited on
/// when the scope exits. If the group exits by throwing, all added tasks will
/// be cancelled and their results discarded.
///
/// ### Implicit awaiting
/// When the group returns it will implicitly await for all spawned tasks to
/// complete. The tasks are only cancelled if `cancelAll()` was invoked before
/// returning, the groups' task was cancelled, or the group body has thrown.
///
/// When results of tasks added to the group need to be collected, one can
/// gather their results using the following pattern:
///
///     while let result = await group.next() {
///       // some accumulation logic (e.g. sum += result)
///     }
///
/// It is also possible to collect results from the group by using its
/// `AsyncSequence` conformance, which enables its use in an asynchronous for-loop,
/// like this:
///
///     for await result in group {
///       // some accumulation logic (e.g. sum += result)
///      }
///
/// ### Cancellation
/// If the task that the group is running in is cancelled, the group becomes 
/// cancelled and all child tasks spawned in the group are cancelled as well.
/// 
/// Since the `withTaskGroup` provided group is specifically non-throwing,
/// child tasks (or the group) cannot react to cancellation by throwing a 
/// `CancellationError`, however they may interrupt their work and e.g. return 
/// some best-effort approximation of their work. 
///
/// If throwing is a good option for the kinds of tasks spawned by the group,
/// consider using the `withThrowingTaskGroup` function instead.
///
/// Postcondition:
/// Once `withTaskGroup` returns it is guaranteed that the `group` is *empty*.
///
/// This is achieved in the following way:
/// - if the body returns normally:
///   - the group will await any not yet complete tasks,
///   - once the `withTaskGroup` returns the group is guaranteed to be empty.
/// - if the body throws:
///   - all tasks remaining in the group will be automatically cancelled.
@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
public func withTaskGroup<ChildTaskResult, GroupResult>(
  of childTaskResultType: ChildTaskResult.Type,
  returning returnType: GroupResult.Type = GroupResult.self,
  body: (inout TaskGroup<ChildTaskResult>) async -> GroupResult
) async -> GroupResult {
  let task = Builtin.getCurrentAsyncTask()
  let _group = _taskGroupCreate()
  var group: TaskGroup<ChildTaskResult>! = TaskGroup(task: task, group: _group)

  // Run the withTaskGroup body.
  let result = await body(&group)

  // Drain any not next() awaited tasks if the group wasn't cancelled
  // If any of these tasks were to throw
  //
  // Failures of tasks are ignored.
  while !group.isEmpty {
    _ = await group.next()
    continue // keep awaiting on all pending tasks
  }

  group = nil
  _taskGroupDestroy(group: _group)
  return result
}

/// Starts a new throwing task group which provides a scope in which a dynamic 
/// number of tasks may be spawned.
///
/// Tasks added to the group by `group.spawn()` will automatically be awaited on
/// when the scope exits. If the group exits by throwing, all added tasks will
/// be cancelled and their results discarded.
///
/// ### Implicit awaiting
/// When the group returns it will implicitly await for all spawned tasks to
/// complete. The tasks are only cancelled if `cancelAll()` was invoked before
/// returning, the groups' task was cancelled, or the group body has thrown.
///
/// When results of tasks added to the group need to be collected, one can
/// gather their results using the following pattern:
///
///     while let result = await try group.next() {
///       // some accumulation logic (e.g. sum += result)
///     }
///
/// It is also possible to collect results from the group by using its
/// `AsyncSequence` conformance, which enables its use in an asynchronous for-loop,
/// like this:
///
///     for try await result in group {
///       // some accumulation logic (e.g. sum += result)
///      }
///
/// ### Thrown errors
/// When tasks are added to the group using the `group.spawn` function, they may
/// immediately begin executing. Even if their results are not collected explicitly
/// and such task throws, and was not yet cancelled, it may result in the `withTaskGroup`
/// throwing.
///
/// ### Cancellation
/// If the task that the group is running in is cancelled, the group becomes 
/// cancelled and all child tasks spawned in the group are cancelled as well.
/// 
/// If an error is thrown out of the task group, all of its remaining tasks
/// will be cancelled and the `withTaskGroup` call will rethrow that error.
///
/// Individual tasks throwing results in their corresponding `try group.next()`
/// call throwing, giving a chance to handle individual errors or letting the
/// error be rethrown by the group.
///
/// Postcondition:
/// Once `withThrowingTaskGroup` returns it is guaranteed that the `group` is *empty*.
///
/// This is achieved in the following way:
/// - if the body returns normally:
///   - the group will await any not yet complete tasks,
///     - if any of those tasks throws, the remaining tasks will be cancelled,
///   - once the `withTaskGroup` returns the group is guaranteed to be empty.
/// - if the body throws:
///   - all tasks remaining in the group will be automatically cancelled.
public func withThrowingTaskGroup<ChildTaskResult, GroupResult>(
  of childTaskResultType: ChildTaskResult.Type,
  returning returnType: GroupResult.Type = GroupResult.self,
  body: (inout ThrowingTaskGroup<ChildTaskResult, Error>) async throws -> GroupResult
) async rethrows -> GroupResult {
  let task = Builtin.getCurrentAsyncTask()
  let _group = _taskGroupCreate()
  var group: ThrowingTaskGroup<ChildTaskResult, Error>! =
    ThrowingTaskGroup(task: task, group: _group)

  do {
    // Run the withTaskGroup body.
    let result = try await body(&group)

    // TODO: For whatever reason extracting the common teardown code into a local async function here causes it to hang forever?!
    // Drain any not next() awaited tasks if the group wasn't cancelled
    // If any of these tasks were to throw
    //
    // Failures of tasks are ignored.
    while !group.isEmpty {
      _ = try? await group.next()
      continue // keep awaiting on all pending tasks
    }
    group = nil
    _taskGroupDestroy(group: _group)

    return result
  } catch {
    group.cancelAll()
    // Drain any not next() awaited tasks if the group wasn't cancelled
    // If any of these tasks were to throw
    //
    // Failures of tasks are ignored.
    while !group.isEmpty {
      _ = try? await group.next()
      continue // keep awaiting on all pending tasks
    }
    group = nil
    _taskGroupDestroy(group: _group)

    throw error
  }
}

/// A task group serves as storage for dynamically spawned tasks.
///
/// It is created by the `withTaskGroup` function.
public struct TaskGroup<ChildTaskResult> {

  private let _task: Builtin.NativeObject
  /// Group task into which child tasks offer their results,
  /// and the `next()` function polls those results from.
  private let _group: Builtin.RawPointer

  /// No public initializers
  init(task: Builtin.NativeObject, group: Builtin.RawPointer) {
    // TODO: this feels slightly off, any other way to avoid the task being too eagerly released?
    _swiftRetain(task) // to avoid the task being destroyed when the group is destroyed

    self._task = task
    self._group = group
  }
  
  /// Add a child task to the group.
  ///
  /// ### Error handling
  /// Operations are allowed to `throw`, in which case the `try await next()`
  /// invocation corresponding to the failed task will re-throw the given task.
  ///
  /// The `add` function will never (re-)throw errors from the `operation`.
  /// Instead, the corresponding `next()` call will throw the error when necessary.
  ///
  /// - Parameters:
  ///   - overridingPriority: override priority of the operation task
  ///   - operation: operation to execute and add to the group
  /// - Returns:
  ///   - `true` if the operation was added to the group successfully,
  ///     `false` otherwise (e.g. because the group `isCancelled`)
  @discardableResult
  public mutating func spawn(
    overridingPriority priorityOverride: Task.Priority? = nil,
    operation: @Sendable @escaping () async -> ChildTaskResult
  ) async -> Bool {
    let canAdd = _taskGroupAddPendingTask(group: _group)
    
    guard canAdd else {
      // the group is cancelled and is not accepting any new work
      return false
    }
    
    // Set up the job flags for a new task.
    var flags = Task.JobFlags()
    flags.kind = .task
    flags.priority = priorityOverride ?? getJobFlags(_task).priority
    flags.isFuture = true
    flags.isChildTask = true
    flags.isGroupChildTask = true
    
    // Create the asynchronous task future.
    let (childTask, _) = Builtin.createAsyncTaskGroupFuture(
      flags.bits, _group, operation)
    
    // Attach it to the group's task record in the current task.
    _ = _taskGroupAttachChild(group: _group, child: childTask)
    
    // Enqueue the resulting job.
    _enqueueJobGlobal(Builtin.convertTaskToJob(childTask))
    
    return true
  }
  
  /// Wait for the a child task that was added to the group to complete,
  /// and return (or rethrow) the value it completed with. If no tasks are
  /// pending in the task group this function returns `nil`, allowing the
  /// following convenient expressions to be written for awaiting for one
  /// or all tasks to complete:
  ///
  /// Await on a single completion:
  ///
  ///     if let first = try await group.next() {
  ///        return first
  ///     }
  ///
  /// Wait and collect all group child task completions:
  ///
  ///     while let first = try await group.next() {
  ///        collected += value
  ///     }
  ///     return collected
  ///
  /// Awaiting on an empty group results in the immediate return of a `nil`
  /// value, without the group task having to suspend.
  ///
  /// It is also possible to use `for await` to collect results of a task groups:
  ///
  ///     for await try value in group {
  ///         collected += value
  ///     }
  ///
  /// ### Thread-safety
  /// Please note that the `group` object MUST NOT escape into another task.
  /// The `group.next()` MUST be awaited from the task that had originally
  /// created the group. It is not allowed to escape the group reference.
  ///
  /// Note also that this is generally prevented by Swift's type-system,
  /// as the `add` operation is `mutating`, and those may not be performed
  /// from concurrent execution contexts, such as child tasks.
  ///
  /// ### Ordering
  /// Order of values returned by next() is *completion order*, and not
  /// submission order. I.e. if tasks are added to the group one after another:
  ///
  ///     await group.spawn { 1 }
  ///     await group.spawn { 2 }
  ///
  ///     print(await group.next())
  ///     /// Prints "1" OR "2"
  ///
  /// ### Errors
  /// If an operation added to the group throws, that error will be rethrown
  /// by the next() call corresponding to that operation's completion.
  ///
  /// It is possible to directly rethrow such error out of a `withTaskGroup` body
  /// function's body, causing all remaining tasks to be implicitly cancelled.
  public mutating func next() async -> ChildTaskResult? {
    #if NDEBUG
    let callingTask = Builtin.getCurrentAsyncTask() // can't inline into the assert sadly
    assert(unsafeBitCast(callingTask, to: size_t.self) ==
      unsafeBitCast(_task, to: size_t.self),
      """
      group.next() invoked from task other than the task which created the group! \
      This means the group must have illegally escaped the withTaskGroup{} scope.
      """)
    #endif
  
    // try!-safe because this function only exists for Failure == Never,
    // and as such, it is impossible to spawn a throwing child task.
    return try! await _taskGroupWaitNext(group: _group)
  }
  
  /// Query whether the group has any remaining tasks.
  ///
  /// Task groups are always empty upon entry to the `withTaskGroup` body, and
  /// become empty again when `withTaskGroup` returns (either by awaiting on all
  /// pending tasks or cancelling them).
  ///
  /// - Returns: `true` if the group has no pending tasks, `false` otherwise.
  public var isEmpty: Bool {
    _taskGroupIsEmpty(_group)
  }

  /// Cancel all the remaining tasks in the group.
  ///
  /// A cancelled group will not will NOT accept new tasks being added into it.
  ///
  /// Any results, including errors thrown by tasks affected by this
  /// cancellation, are silently discarded.
  ///
  /// This function may be called even from within child (or any other) tasks,
  /// and will reliably cause the group to become cancelled.
  ///
  /// - SeeAlso: `Task.isCancelled`
  /// - SeeAlso: `TaskGroup.isCancelled`
  public func cancelAll() {
    _taskGroupCancelAll(group: _group)
  }

  /// Returns `true` if the group was cancelled, e.g. by `cancelAll`.
  ///
  /// If the task currently running this group was cancelled, the group will
  /// also be implicitly cancelled, which will be reflected in the return
  /// value of this function as well.
  ///
  /// - Returns: `true` if the group (or its parent task) was cancelled,
  ///            `false` otherwise.
  public var isCancelled: Bool {
    return _taskIsCancelled(_task) ||
      _taskGroupIsCancelled(group: _group)
  }
}

// Implementation note:
// We are unable to just™ abstract over Failure == Error / Never because of the
// complicated relationship between `group.spawn` which dictates if `group.next`
// AND the AsyncSequence conformances would be throwing or not.
//
// We would be able to abstract over TaskGroup<..., Failure> equal to Never
// or Error, and specifically only add the `spawn` and `next` functions for
// those two cases. However, we are not able to conform to AsyncSequence "twice"
// depending on if the Failure is Error or Never, as we'll hit:
//    conflicting conformance of 'TaskGroup<ChildTaskResult, Failure>' to protocol
//    'AsyncSequence'; there cannot be more than one conformance, even with
//    different conditional bounds
// So, sadly we're forced to duplicate the entire implementation of TaskGroup
// to TaskGroup and ThrowingTaskGroup.
//
// The throwing task group is parameterized with failure only because of future
// proofing, in case we'd ever have typed errors, however unlikely this may be.
// Today the throwing task group failure is simply automatically bound to `Error`.

/// A task group serves as storage for dynamically spawned, potentially throwing,
/// child tasks.
///
/// It is created by the `withTaskGroup` function.
public struct ThrowingTaskGroup<ChildTaskResult, Failure: Error> {

  private let _task: Builtin.NativeObject
  /// Group task into which child tasks offer their results,
  /// and the `next()` function polls those results from.
  private let _group: Builtin.RawPointer

  /// No public initializers
  init(task: Builtin.NativeObject, group: Builtin.RawPointer) {
    // FIXME: this feels slightly off, any other way to avoid the task being too eagerly released?
    _swiftRetain(task) // to avoid the task being destroyed when the group is destroyed

    self._task = task
    self._group = group
  }

  /// Add a child task to the group.
  ///
  /// ### Error handling
  /// Operations are allowed to `throw`, in which case the `try await next()`
  /// invocation corresponding to the failed task will re-throw the given task.
  ///
  /// The `add` function will never (re-)throw errors from the `operation`.
  /// Instead, the corresponding `next()` call will throw the error when necessary.
  ///
  /// - Parameters:
  ///   - overridingPriority: override priority of the operation task
  ///   - operation: operation to execute and add to the group
  /// - Returns:
  ///   - `true` if the operation was added to the group successfully,
  ///     `false` otherwise (e.g. because the group `isCancelled`)
  @discardableResult
  public mutating func spawn(
    overridingPriority priorityOverride: Task.Priority? = nil,
    operation: __owned @Sendable @escaping () async throws -> ChildTaskResult
  ) async -> Bool {
    let canAdd = _taskGroupAddPendingTask(group: _group)

    guard canAdd else {
      // the group is cancelled and is not accepting any new work
      return false
    }

    // Set up the job flags for a new task.
    var flags = Task.JobFlags()
    flags.kind = .task
    flags.priority = priorityOverride ?? getJobFlags(_task).priority
    flags.isFuture = true
    flags.isChildTask = true
    flags.isGroupChildTask = true

    // Create the asynchronous task future.
    let (childTask, _) = Builtin.createAsyncTaskGroupFuture(
      flags.bits, _group, operation)

    // Attach it to the group's task record in the current task.
    _ = _taskGroupAttachChild(group: _group, child: childTask)

    // Enqueue the resulting job.
    _enqueueJobGlobal(Builtin.convertTaskToJob(childTask))

    return true
  }

  /// Wait for the a child task that was added to the group to complete,
  /// and return (or rethrow) the value it completed with. If no tasks are
  /// pending in the task group this function returns `nil`, allowing the
  /// following convenient expressions to be written for awaiting for one
  /// or all tasks to complete:
  ///
  /// Await on a single completion:
  ///
  ///     if let first = try await group.next() {
  ///        return first
  ///     }
  ///
  /// Wait and collect all group child task completions:
  ///
  ///     while let first = try await group.next() {
  ///        collected += value
  ///     }
  ///     return collected
  ///
  /// Awaiting on an empty group results in the immediate return of a `nil`
  /// value, without the group task having to suspend.
  ///
  /// It is also possible to use `for await` to collect results of a task groups:
  ///
  ///     for await try value in group {
  ///         collected += value
  ///     }
  ///
  /// ### Thread-safety
  /// Please note that the `group` object MUST NOT escape into another task.
  /// The `group.next()` MUST be awaited from the task that had originally
  /// created the group. It is not allowed to escape the group reference.
  ///
  /// Note also that this is generally prevented by Swift's type-system,
  /// as the `add` operation is `mutating`, and those may not be performed
  /// from concurrent execution contexts, such as child tasks.
  ///
  /// ### Ordering
  /// Order of values returned by next() is *completion order*, and not
  /// submission order. I.e. if tasks are added to the group one after another:
  ///
  ///     await group.spawn { 1 }
  ///     await group.spawn { 2 }
  ///
  ///     print(await group.next())
  ///     /// Prints "1" OR "2"
  ///
  /// ### Errors
  /// If an operation added to the group throws, that error will be rethrown
  /// by the next() call corresponding to that operation's completion.
  ///
  /// It is possible to directly rethrow such error out of a `withTaskGroup` body
  /// function's body, causing all remaining tasks to be implicitly cancelled.
  public mutating func next() async throws -> ChildTaskResult? {
    #if NDEBUG
    let callingTask = Builtin.getCurrentAsyncTask() // can't inline into the assert sadly
    assert(unsafeBitCast(callingTask, to: size_t.self) ==
      unsafeBitCast(_task, to: size_t.self),
      """
      group.next() invoked from task other than the task which created the group! \
      This means the group must have illegally escaped the withTaskGroup{} scope.
      """)
    #endif

    return try await _taskGroupWaitNext(group: _group)
  }

  /// Query whether the group has any remaining tasks.
  ///
  /// Task groups are always empty upon entry to the `withTaskGroup` body, and
  /// become empty again when `withTaskGroup` returns (either by awaiting on all
  /// pending tasks or cancelling them).
  ///
  /// - Returns: `true` if the group has no pending tasks, `false` otherwise.
  public var isEmpty: Bool {
    _taskGroupIsEmpty(_group)
  }

  /// Cancel all the remaining tasks in the group.
  ///
  /// A cancelled group will not will NOT accept new tasks being added into it.
  ///
  /// Any results, including errors thrown by tasks affected by this
  /// cancellation, are silently discarded.
  ///
  /// This function may be called even from within child (or any other) tasks,
  /// and will reliably cause the group to become cancelled.
  ///
  /// - SeeAlso: `Task.isCancelled`
  /// - SeeAlso: `TaskGroup.isCancelled`
  public func cancelAll() {
    _taskGroupCancelAll(group: _group)
  }

  /// Returns `true` if the group was cancelled, e.g. by `cancelAll`.
  ///
  /// If the task currently running this group was cancelled, the group will
  /// also be implicitly cancelled, which will be reflected in the return
  /// value of this function as well.
  ///
  /// - Returns: `true` if the group (or its parent task) was cancelled,
  ///            `false` otherwise.
  public var isCancelled: Bool {
    return _taskIsCancelled(_task) ||
      _taskGroupIsCancelled(group: _group)
  }
}

/// ==== TaskGroup: AsyncSequence ----------------------------------------------

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
extension TaskGroup: AsyncSequence {
  public typealias AsyncIterator = Iterator
  public typealias Element = ChildTaskResult

  public func makeAsyncIterator() -> Iterator {
    return Iterator(group: self)
  }

  /// Allows iterating over results of tasks added to the group.
  ///
  /// The order of elements returned by this iterator is the same as manually
  /// invoking the `group.next()` function in a loop, meaning that results
  /// are returned in *completion order*.
  ///
  /// This iterator terminates after all tasks have completed successfully, or
  /// after any task completes by throwing an error.
  ///
  /// - SeeAlso: `TaskGroup.next()`
  public struct Iterator: AsyncIteratorProtocol {
    public typealias Element = ChildTaskResult

    @usableFromInline
    var group: TaskGroup<ChildTaskResult>

    @usableFromInline
    var finished: Bool = false

    // no public constructors
    init(group: TaskGroup<ChildTaskResult>) {
      self.group = group
    }

    /// Once this function returns `nil` this specific iterator is guaranteed to
    /// never produce more values.
    /// - SeeAlso: `TaskGroup.next()` for a detailed discussion its semantics.
    public mutating func next() async -> Element? {
      guard !finished else { return nil }
      guard let element = try await group.next() else {
        finished = true
        return nil
      }
      return element
    }

    public mutating func cancel() {
      finished = true
      group.cancelAll()
    }
  }
}

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
extension ThrowingTaskGroup: AsyncSequence {
  public typealias AsyncIterator = Iterator
  public typealias Element = ChildTaskResult

  public func makeAsyncIterator() -> Iterator {
    return Iterator(group: self)
  }

  /// Allows iterating over results of tasks added to the group.
  ///
  /// The order of elements returned by this iterator is the same as manually
  /// invoking the `group.next()` function in a loop, meaning that results
  /// are returned in *completion order*.
  ///
  /// This iterator terminates after all tasks have completed successfully, or
  /// after any task completes by throwing an error. If a task completes by
  /// throwing an error, no further task results are returned.
  ///
  /// - SeeAlso: `ThrowingTaskGroup.next()`
  public struct Iterator: AsyncIteratorProtocol {
    public typealias Element = ChildTaskResult

    @usableFromInline
    var group: ThrowingTaskGroup<ChildTaskResult, Failure>

    @usableFromInline
    var finished: Bool = false

    // no public constructors
    init(group: ThrowingTaskGroup<ChildTaskResult, Failure>) {
      self.group = group
    }

    /// - SeeAlso: `ThrowingTaskGroup.next()` for a detailed discussion its semantics.
    public mutating func next() async throws -> Element? {
      do {
        guard let element = try await group.next() else {
          finished = true
          return nil
        }
        return element
      } catch {
        finished = true
        throw error
      }
    }

    public mutating func cancel() {
      finished = true
      group.cancelAll()
    }
  }
}

/// ==== -----------------------------------------------------------------------

// FIXME: remove this
@_silgen_name("swift_retain")
func _swiftRetain(
  _ object: Builtin.NativeObject
)

// FIXME: remove this
@_silgen_name("swift_release")
func _swiftRelease(
  _ object: Builtin.NativeObject
)

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
@_silgen_name("swift_taskGroup_create")
func _taskGroupCreate() -> Builtin.RawPointer

/// Attach task group child to the group group to the task.
@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
@_silgen_name("swift_taskGroup_attachChild")
func _taskGroupAttachChild(
  group: Builtin.RawPointer,
  child: Builtin.NativeObject
) -> UnsafeRawPointer /*ChildTaskStatusRecord*/

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
@_silgen_name("swift_taskGroup_destroy")
func _taskGroupDestroy(group: __owned Builtin.RawPointer)

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
@_silgen_name("swift_taskGroup_addPending")
func _taskGroupAddPendingTask(
  group: Builtin.RawPointer
) -> Bool

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
@_silgen_name("swift_taskGroup_cancelAll")
func _taskGroupCancelAll(group: Builtin.RawPointer)

/// Checks ONLY if the group was specifically cancelled.
/// The task itself being cancelled must be checked separately.
@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
@_silgen_name("swift_taskGroup_isCancelled")
func _taskGroupIsCancelled(group: Builtin.RawPointer) -> Bool

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
@_silgen_name("swift_taskGroup_wait_next_throwing")
func _taskGroupWaitNext<T>(group: Builtin.RawPointer) async throws -> T?

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
enum PollStatus: Int {
  case empty   = 0
  case waiting = 1
  case success = 2
  case error   = 3
}

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
@_silgen_name("swift_taskGroup_isEmpty")
func _taskGroupIsEmpty(
  _ group: Builtin.RawPointer
) -> Bool
