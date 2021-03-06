// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library sintr_common.tasks;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gcloud/db.dart' as db;
import 'package:sintr_live_common/gae_utils.dart';
import 'package:sintr_live_common/logging_utils.dart' as log;
import 'package:uuid/uuid.dart';

const int DATASTORE_TRANSACTION_SIZE = 250;
const String _UNALLOCATED_OWNER = "";
const Duration BACKING_STORE_STALE_POLICY = const Duration(seconds: 120);


db.DatastoreDB _db = db.dbService;

/// Abstraction over a piece of work to be done by a compute node
class Task {
  // Location of the object in the datastore
  final db.Key _objectKey;
  _TaskModel backingstore;
  Stopwatch backingStoreAge;

  toString() => uniqueName;

  String get uniqueName => "${_objectKey?.id}";

  /// Force the infrastructure to resync the backing store for this object
  /// This will incur a datastore read
  Future forceReadSync() => _pullBackingStore();

  /// Sync the backing store if it is empty of if the policy determines
  /// it is stale
  Future _policyBasedSyncBackingStore() async {
    if (backingstore == null) {
      log.trace("BackingStore was null, syncing");
      await _pullBackingStore();
    } else if (backingStoreAge != null
      && backingStoreAge.elapsed > BACKING_STORE_STALE_POLICY) {
        log.trace("BackingStore was stale: ${backingStoreAge.elapsed}, syncing");
        await _pullBackingStore();
    } else {
      log.trace("BackingStore cache used");
    }
  }

  /// Get the state of the task
  /// The state machine for READY -> ALLOCATED is synchronised
  /// This call requests a resync
  Future<LifecycleState> get state async {
    log.trace("Get state on Task for $_objectKey");
    await _pullBackingStore();
    if (backingstore == null) return null;

    LifecycleState result = _lifecyclefromInt(backingstore.lifecycleState);
    log.trace("Get state on Task for $_objectKey -> $result: OK");
    return result;
  }

  // TODO(lukechurch): This needs adapting to use the owner field to ensure
  // that we successfully take ownership of the node
  Future setState(LifecycleState state) async {
    if (state == LifecycleState.ALLOCATED) {
      throw "Setting tasks to allocated may only be done by the TaskController";
    }
    log.trace("Set state on Task for $_objectKey -> $state");

    await _pullBackingStore();
    int lifeCycleStateInt = _intFromLifecycle(state);
    backingstore.lifecycleState = lifeCycleStateInt;
    await _pushBackingStore();

    log.trace("Set state on Task for $_objectKey -> $state : OK");
  }

  /// Number of times this task has failed to execute
  /// Policy based syncronisation
  Future<int> get failureCounts async {
    log.trace("Get failureCounts on Task for $_objectKey");
    await _policyBasedSyncBackingStore();

    return backingstore?.failureCount;
  }

  // Last time this task was pinged as having made progress
  // Best effort syncronised
  Future<int> get lastUpdateEpochMs async {
    log.trace("Get lastUpdateEpochMs on Task for $_objectKey");
    await _pullBackingStore();
    if (backingstore == null) return null;

    return backingstore.lastUpdateEpochMs;
  }

  Future<Map<String, String>> get source async {
    log.trace("Get source on Task for $_objectKey");

    await _policyBasedSyncBackingStore();
    if (backingstore == null) return null;

    List<int> sourceBlob = backingstore.sourceBlob;
    return JSON.decode(UTF8.decode(GZIP.decode(sourceBlob)));
  }

  Future<String> get input async {
    log.trace("Get input on Task for $_objectKey");

    await _policyBasedSyncBackingStore();
    if (backingstore == null) return null;

    return UTF8.decode(GZIP.decode(backingstore.inputBlob));

    // return backingstore.input;
  }

  Future<String> get result async {
    log.trace("Get result on Task for $_objectKey");

    await _policyBasedSyncBackingStore();
    if (backingstore == null) return null;

    return UTF8.decode(GZIP.decode(backingstore.outputBlob));

    // return backingstore.output;
  }

  Future setResult(String result) async {
    log.trace("Set result on Task for $_objectKey -> $result");


    backingstore.outputBlob = GZIP.encode(UTF8.encode(result));
    await _pushBackingStore();
    log.trace("Set result on Task for $_objectKey -> $result : OK");
  }

  /// Record that this task has made progress
  /// Based effort based synchronisation
  recordProgress() async {
    log.trace("recordProgress on Task for $_objectKey");
    await _pullBackingStore();

    int msSinceEpoch = new DateTime.now().millisecondsSinceEpoch;
    backingstore.lastUpdateEpochMs = msSinceEpoch;
    await _pushBackingStore();
  }

  // Update the in memory version from datastore
  Future _pullBackingStore() async {
    var sw = new Stopwatch()..start();
    log.trace("_pullBackingStore on Task for $_objectKey");

    List<db.Model> models = await _db.lookup([_objectKey]);
    backingstore = models.first;

    backingStoreAge = new Stopwatch()..start();

    log.trace("_pullBackingStore completed, PERF: ${sw.elapsedMilliseconds}");
  }

  // Writeback the in memory version to datastore
  // NB: Datastore is eventually consistent, nodes may still see old
  // copies after this call has returned
  Future _pushBackingStore() async {
    var sw = new Stopwatch()..start();
    log.trace("_pushBackingStore on Task for $_objectKey");

    await _db.commit(inserts: [backingstore]);

    log.trace("_pushBackingStore completed, PERF: ${sw.elapsedMilliseconds}");
  }

  Task._fromTaskKey(this._objectKey);

  Task._fromTaskModel(_TaskModel backingstore)
      : this._objectKey = backingstore.key,
        this.backingstore = backingstore;
}

/// Datamodel for storing tasks in Datastore
@db.Kind()
class _TaskModel extends db.Model {
  @db.StringProperty()
  String jobName;

  @db.IntProperty()
  int lifecycleState;

  @db.IntProperty()
  int lastUpdateEpochMs;

  @db.IntProperty()
  int creationEpochMs;

  @db.IntProperty()
  int failureCount;

  // Input/Output

  // @db.StringProperty()
  // String input;

  @db.BlobProperty()
  List<int> inputBlob;

  // @db.StringProperty()
  // String output;

  @db.BlobProperty()
  List<int> outputBlob;


  // Source

  @db.BlobProperty()
  List<int> sourceBlob;

  @db.StringProperty()
  String ownerID;

  _TaskModel();

  _TaskModel.fromData(
      this.jobName,
      String input,
      Map<String, String> sources) {
    lifecycleState = _intFromLifecycle(LifecycleState.READY);
    lastUpdateEpochMs = new DateTime.now().millisecondsSinceEpoch;
    creationEpochMs = lastUpdateEpochMs;
    failureCount = 0;
    ownerID = _UNALLOCATED_OWNER;

    inputBlob = GZIP.encode(UTF8.encode(input));
    sourceBlob = GZIP.encode(UTF8.encode(JSON.encode(sources)));
  }
}

/// [LifecycleState] tracks a task through its lifetime
enum LifecycleState {
  READY, // Ready for allocation
  ALLOCATED, // Allocated to a node
  STARTED, // Execution has begun, this may go back to READY if it fails
  DONE, // Successfully compute
  DEAD // Terminally dead, won't be retried
}

LifecycleState _lifecyclefromInt(int i) => LifecycleState.values[i];
int _intFromLifecycle(LifecycleState state) =>
    LifecycleState.values.indexOf(state);

/// Class that manages the creation and allocation of the work to be done
/// Multiple nodes are expected to make concurrent calls to this API
class TaskController {
  String jobName;
  String ownerID;

  TaskController(this.jobName) {
    // TODO(lukechurch): Replace this with a gaurenteed unqiueness
    ownerID = new Uuid().v4();
  }

  // Get the next task that is ready for execution and switch it to
  // allocated. Returns null if there are no available tasks needing further
  // work
  Future<Task> getNextReadyTask() async {
    const int MAX_OWNERSHIP_ATTEMPTS = 120;
    const Duration OWNERNSHIP_ATTEMPT_DELAY = const Duration (seconds: 1);

    log.trace("getNextReadyTask() started");

    // TODO: Implement an error management wrapper so this is error tolerant

    // TODO: This algorithm has a race condition where two nodes
    // can both decide they got the task.

    final int READY_STATE = _intFromLifecycle(LifecycleState.READY);
    final int ALLOCATED_STATE = _intFromLifecycle(LifecycleState.ALLOCATED);

    // TODO: Add co-ordination of the job to outside the control scripts
    var query = _db.query(_TaskModel)
      ..order("-creationEpochMs")
      ..filter("lifecycleState =", READY_STATE)..limit(100);

    await for (_TaskModel model in query.run()) {
      model.lifecycleState = ALLOCATED_STATE;
      model.ownerID = ownerID;

      Task task = new Task._fromTaskModel(model);
      await task._pushBackingStore();

      int takeOwnershipAttemptCount = 0;

      // Test to see if we got the task
      while (true) {

        if (takeOwnershipAttemptCount++ > MAX_OWNERSHIP_ATTEMPTS) {
          log.alert("WARNING: Too many polls needed to determine task ownership:"
            " $takeOwnershipAttemptCount");
          break;
        }
        await task._pullBackingStore();

        if (task.backingstore.ownerID == ownerID) {
          return task;
        } else if (task.backingstore.ownerID == _UNALLOCATED_OWNER) {
          // Datastore isn't consistent yet sync hasn't completed yet
          await new Future.delayed(OWNERNSHIP_ATTEMPT_DELAY);
          continue;
        }
        // Someone else got this task
        break;
      }
    }
    // We couldn't find a model that wasn't already in use
    return null;
  }

  // Utility methods
  Future createTasks(
      List<String> inputs,
      Map<String, String> sources) async {
    log.info("Creating ${inputs.length} tasks");

    int count = 0;

    // TODO this needs resiliance adding to it to protect against
    // datastore errors

    var inserts = <_TaskModel>[];
    for (String input in inputs) {
      _TaskModel task = new _TaskModel.fromData(
          jobName,
          input,
          sources);
      inserts.add(task);

      if (inserts.length >= DATASTORE_TRANSACTION_SIZE) {
        count += inserts.length;
        await _db.commit(inserts: inserts);

        log.info("Tasks committed: $count");
        inserts.clear();
      }
    }

    if (inserts.length > 0) {
      count += inserts.length;
      await _db.commit(inserts: inserts);

      log.info("Tasks committed: $count");
      inserts.clear();
    }
  }

  Future deleteAllTasks() async {
    log.info("Deleting all tasks");

    int i = 0;
    var query = _db.query(_TaskModel);
    var deleteKeys = [];

    await for (var model in query.run()) {
      deleteKeys.add(model.key);

      if (deleteKeys.length >= DATASTORE_TRANSACTION_SIZE) {
        await _db.commit(deletes: deleteKeys);
        i += deleteKeys.length;
        log.info("$i tasks deleted");
        deleteKeys.clear();
      }
    }

    if (deleteKeys.length > 0) {
      await _db.commit(deletes: deleteKeys);
      i += deleteKeys.length;
    }
    log.info("$i tasks deleted");
  }

  Future<List<String>> queryResultsForJob() async {
    log.info("Query results for $jobName");

    final int DONE_STATE = _intFromLifecycle(LifecycleState.DONE);
    var query = _db.query(_TaskModel)
      ..filter("lifecycleState =", DONE_STATE)
      ..filter("jobName =", jobName);

      List<String> results = [];

    await for (_TaskModel model in query.run()) {
      Task t = new Task._fromTaskModel(model);
       results.add(await t.result);
    }

    return results;
  }

  Future<Map<String, int>> queryTasksReady() async {
    log.info("Query task ready");
    // Task -> ready count
    Map<String, int> readyCounts = {};

    final int READY_STATE = _intFromLifecycle(LifecycleState.READY);

    var query = _db.query(_TaskModel)..filter("lifecycleState =", READY_STATE);

    await for (_TaskModel model in query.run()) {
      String parentJobName = model.jobName;
      readyCounts.putIfAbsent(parentJobName, () => 0);
      readyCounts[parentJobName]++;
    }
    return readyCounts;
  }

  Future<Map<String, Map<int, int>>> queryTaskState() async {
    log.info("Query task state");

    // Task -> state - count
    Map<String, Map<int, int>> stateCounts = {};

    int i = 0;
    var query = _db.query(_TaskModel);
    await for (_TaskModel model in query.run()) {
      String parentJobName = model.jobName;
      int state = model.lifecycleState;

      stateCounts.putIfAbsent(parentJobName, () => {});
      stateCounts[parentJobName].putIfAbsent(state, () => 0);
      stateCounts[parentJobName][state]++;

      i++;
    }
    log.info("$i tasks read");

    return stateCounts;
  }

  /// Mapping of an [inputLocation] for a task to an output location
  String outputPathFromInput(CloudStorageLocation inputLocation) =>
      "$jobName/out/${inputLocation.objectPath}";
}
