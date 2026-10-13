## glyphes — crash child: a deterministic importer that can be killed.
##
## Run by `crash_harness.nim`, which SIGKILLs it at a random moment and
## then checks what came back. This process never checks anything itself:
## a test that asserts its own success is a test that cannot fail usefully.
##
## The schedule is a pure function of (seed, ops, opsPerTxn), so the parent
## can predict exactly what any prefix of it produced. That is what makes
## "recovered to the last committed transaction" checkable rather than
## "looks about right".
##
## ##1 The marker lives inside the transaction, not beside it
##
## Each transaction ends by writing `marker.txn = <index>` as part of the
## same commit. A marker file written *after* the commit would be a race:
## kill -9 between the fsync of the WAL and the write of the marker leaves
## the marker one transaction behind the truth, and every assertion built
## on it has to allow for that. Putting it in the graph makes it atomic by
## construction — the marker and the data either both survive or neither
## does.
##
## Usage: crash_child <path> <seed> <ops> <opsPerTxn>

import std/os
import std/random
import std/strutils
import ../../src/store/prop
import ../../src/store/store
import ../../src/wal/wal
import ../../src/wal/snapshot
import ../../src/wal/recover
import ../../src/txn/txn

proc run() =
  let path = paramStr(1)
  let seed = parseInt(paramStr(2))
  let ops = parseInt(paramStr(3))
  let opsPerTxn = parseInt(paramStr(4))

  let store = newStore()
  let wal = openWal(path & "-wal")
  var txnId = 0'u32
  var done = 0
  var madeNodes: seq[int64] = @[]
  var madeEdges: seq[int64] = @[]

  while done < ops:
    inc txnId
    let tx = begin(store, wal, txnId, doSync = false)
    ## Seeded per transaction so the schedule is a pure function of
    ## (seed, txnId) and any prefix of it is predictable.
    var rng = initRand(int64(seed) * 1000003'i64 + int64(txnId))
    for k in 0 ..< opsPerTxn:
      if done >= ops:
        break
      let r = rng.rand(100)
      if r < 55 or madeNodes.len < 8:
        let label = ["Person", "Company", "Doc", "Tag"][rng.rand(3)]
        let id = tx.createNode(label)
        if id != 0:
          madeNodes.add id
          discard tx.setNodeProp(id, "n", Value(kind: vkInt, i: int64(id)))
          # Every 8th node gets an overflowing string, so the log carries
          # blobs and the arena-copy path is exercised by the crash gate
          # and not only by the unit tests.
          if id mod 8 == 0:
            discard tx.setNodeProp(id, "bio",
              Value(kind: vkString, s: "bio-" & $id & "-" & "x".repeat(60)))
      elif r < 90:
        let a = madeNodes[rng.rand(madeNodes.high)]
        let b = madeNodes[rng.rand(madeNodes.high)]
        let e = tx.createEdge(a, b, if rng.rand(2) == 0: "KNOWS" else: "OWNS")
        if e != 0:
          madeEdges.add e
          discard tx.setEdgeProp(e, "w", Value(kind: vkFloat, f: rng.rand(1000).float64 / 1000.0))
      else:
        # Deletes, so recovery has tombstones and cascades to get right.
        if madeEdges.len > 16:
          let e = madeEdges[rng.rand(madeEdges.high)]
          if tx.edgeExistsTx(e):
            discard tx.deleteEdge(e)
        elif madeNodes.len > 32:
          let n = madeNodes[rng.rand(madeNodes.high)]
          if tx.nodeExistsTx(n):
            discard tx.deleteNode(n, true)
      inc done
    # Narrow it: the defect is reported as an index into a seq of length
    # The marker, inside the commit.
    let markerNode = tx.createNode("Marker")
    discard tx.setNodeProp(markerNode, "txn", Value(kind: vkInt, i: int64(txnId)))
    discard tx.commit()

    ## Checkpoint every 50 transactions so the harness also exercises the
    ## snapshot-plus-WAL-replay path rather than only WAL replay.
    if txnId mod 50 == 0 and getEnv("GLYPHES_SKIP_SNAPSHOT") == "":
      writeSnapshot(store, path, uint64(wal.nextLsn - 1))

  if getEnv("GLYPHES_SKIP_SNAPSHOT") == "":
    writeSnapshot(store, path, uint64(wal.nextLsn - 1))
  closeWal(wal)
  stdout.writeLine "CLEAN " & $txnId & " (ops=" & $ops & " opsPerTxn=" &
    $opsPerTxn & " seed=" & $seed & ")"

proc main() =
  ## Any failure here is an engine bug rather than a child bug, so the
  ## traceback is reported instead of letting a Defect print one line
  ## and an index.
  try:
    run()
  except CatchableError as e:
    stderr.writeLine "CHILD FAILED: " & e.msg & "\n" & e.getStackTrace()
    quit(1)

main()
