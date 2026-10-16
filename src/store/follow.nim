## follow — a read-only observer of a database's commit history.
##
## A follower is not a second handle on the graph and not a peer writer. It is
## the reader half of PRD-SHARED: it maps the 16-byte watermark, reads the
## `.vhist` sidecar up to the generation that watermark names, and builds a
## `Revisions` timeline that belongs to nobody else. It holds no graph, issues
## no Cypher, takes no writer lock, and never writes to the database
## directory -- including never truncating the sidecar, which is the one
## operation `replayHistory` does that a follower must not.
##
## The watermark is the only thing that makes this safe. `.vhist` can be ahead
## of the graph after a crash (frames are fsynced before the commit record is),
## so "read to end of file" would show a follower commits that were rolled
## back. Reading to `committedGeneration` cannot: the watermark is published
## after the frames it covers are durable, and the release/acquire pair in
## shm.nim means a follower that sees the generation also sees those frames.

import std/[os, tables]

import ./revision
import ./vhist
import ./shm

type
  Follower* = ref object
    ## One observer of one database. Cheap to create and independent of any
    ## `Database`: nothing here can read or write a node.
    path*: string          ## the database path this follower observes
    shm*: Shm              ## the mapped watermark; nil if none was available
    revisions*: Revisions  ## the timeline built so far
    bytes*: int            ## how far into `.vhist` we have replayed (a good offset)
    watermark*: uint64     ## the generation last applied; 0 = nothing yet
    lsn*: uint64           ## the committed LSN paired with `watermark`
    ## The newest **commit id** applied. Not the same number as `watermark`:
    ## generations and commit ids advance together but are numbered
    ## independently, so the timeline API needs its own counter. Using one for
    ## both produces a history that is present and unreachable at the same time.
    headCommit*: uint64
    ## Why the watermark was unavailable, or "" if it was. Non-fatal: a
    ## follower with no watermark has no history to follow, and says so
    ## rather than reporting a head of 0 it cannot distinguish from a real one.
    unavailable*: string

proc replayInto*(rv: Revisions; path: string; fromByte: int;
                 uptoGeneration: uint64): tuple[goodBytes: int,
                                               applied: int, stopped: bool,
                                               lastCommit: uint64] =
  ## Fold `.vhist` frames `[fromByte, uptoGeneration]` into `rv`, and report
  ## how far the fold got.
  ##
  ## `stopped` is true when a frame was declined — past the watermark, or torn.
  ## A follower does *not* act on it: the untrusted tail is the writer's to
  ## discard, and a reader that truncated the sidecar would be a writer by
  ## another name. The only thing the reader does with `stopped` is stop.
  ##
  ## Replayed in the same open/seal sequence a live writer uses, so a
  ## follower's timeline is identical in shape to the writer's own — a diff
  ## that meant different things on the two sides would be worse than no diff.
  let replay = replayVhist(path, uptoGeneration, fromByte)
  for fr in replay.frames:
    let dec = decodeCommitPayload(fr.payload)
    let cid = rv.openCommit("", dec.parents, dec.lsn)
    ## `changed` is authoritative (vhist.nim), so a node named by the commit
    ## with no row records an empty live revision — the same state a commit
    ## that touched a node and left it identical would have.
    for id in dec.changed:
      let rev = dec.revisions.getOrDefault(id, Revision(commit: cid, live: true))
      rv.noteRevision(cid, id, rev.props, rev.live, rev.removed)
    rv.sealCommit(cid)
  result.goodBytes = replay.goodBytes
  result.applied = replay.frames.len
  result.stopped = replay.truncated
  ## The last commit *id*, kept separate from the generation it arrived under.
  ## These are different counters — a database's generation and its commit ids
  ## advance on the same transactions but are numbered independently — and
  ## conflating them is a mistake this very function is named to prevent.
  if replay.frames.len > 0:
    result.lastCommit = replay.frames[^1].commitId

proc openFollower*(path: string): Follower =
  ## Attach to `path` read-only. Does not replay yet — call `refresh`.
  ##
  ## A missing or unmappable watermark is reported in `unavailable`, not
  ## raised. The follower still exists, holds an empty timeline, and
  ## `refresh` can succeed later if the writer appears: attaching to a
  ## database before its writer has published is an ordinary race, not an
  ## error, and refusing it would make follower startup depend on timing.
  new(result)
  result.path = path
  result.revisions = initRevisions()
  try:
    result.shm = openShmReadOnly(path)
  except IOError as e:
    result.unavailable = "watermark unavailable: " & e.msg

proc refresh*(f: Follower): bool =
  ## Apply everything the watermark now covers. Returns true if new commits
  ## were folded in.
  ##
  ## Re-reads the watermark first, every call, and applies only frames past
  ## what it already has. That makes the cost O(new commits) rather than
  ## O(history) per tick, which is the difference between a follower that
  ## keeps up and one that falls further behind the longer it runs.
  if f.shm == nil:
    ## Attached before the writer existed. Retrying here is what makes that a
    ## race rather than a dead end: a follower that attached to a watermark
    ## that was not there yet would otherwise watch nothing for the rest of
    ## its life, which is the most common way to be followed at all.
    try:
      f.shm = openShmReadOnly(f.path)
      f.unavailable = ""
    except IOError:
      return false
  let generation = f.shm.loadGeneration()
  let lsn = f.shm.loadLsn()
  if generation <= f.watermark:
    ## Nothing new. Keep the LSN paired with the generation already applied;
    ## re-reading it here would only ever restate what `f.watermark` names.
    return false
  ## The watermark moved. Both halves are read, and the pair is recorded only
  ## after the frames are folded — so a follower interrupted mid-refresh
  ## resumes from the older generation and re-applies, which is idempotent,
  ## rather than recording progress it never made.
  let res = replayInto(f.revisions, f.path, f.bytes, generation)
  ## Advance all three counters only after the frames are folded. A follower
  ## interrupted mid-refresh resumes from the older offset and re-applies,
  ## which is idempotent — whereas recording progress it never made would skip
  ## commits permanently, and a follower that silently skips commits is the one
  ## failure mode this whole feature exists to prevent.
  f.bytes = res.goodBytes
  if res.lastCommit > f.headCommit:
    f.headCommit = res.lastCommit
  f.watermark = generation
  f.lsn = lsn
  return true

proc head*(f: Follower): uint64 =
  ## The newest commit **id** this follower has applied, or 0 if none. This is
  ## a commit id, not a generation — `head` is for asking the timeline a
  ## question, and the timeline is indexed by commit id.
  f.headCommit

proc generation*(f: Follower): uint64 =
  ## The generation of the watermark, for asking the *writer's* progress a
  ## question. Distinct from `head`, because generation and commit id are
  ## different counters even though they advance together.
  f.watermark

proc revisions*(f: Follower): Revisions =
  ## The timeline. Shared, not copied: `Revisions` is append-only and the
  ## follower owns it outright, so handing out the reference saves a deep copy
  ## that the type's own design makes unnecessary.
  f.revisions

proc followAt*(f: Follower; generation: uint64): seq[CommitRecord] =
  ## The commits from `generation` up to the follower's head, newest first
  ## (the order `commitsOnPath` defines, which is a total order regardless of
  ## branch shape).
  ##
  ## This is an audit trail, not a graph query: it answers "what changed
  ## between here and now", and it deliberately cannot answer "what is the
  ## graph now" — nodes are not reconstructed, because the follower's job is
  ## to witness commits, not to hold a second copy of the store.
  if generation >= f.headCommit or f.revisions == nil:
    return @[]
  result = f.revisions.commitsOnPath(generation, f.headCommit)
