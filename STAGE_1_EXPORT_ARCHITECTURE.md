# Stage 1 — Export Architecture

The exact film renderer is unchanged.

Pipeline:

decode N+1
    ||
exact GPU render N
    ||
bounded post-render pool for N-1 / N-2 / ...

The post-render pool owns:
- geometry
- export resize
- float-to-image conversion
- metadata
- compression
- verification
- atomic commit

Worker ceiling: 4.

Actual concurrency can be lower because the memory byte budget wins over
the worker ceiling for large Intel-Mac images.

`ExportEngine` is now a Sendable value type instead of an actor. The old
actor method was synchronous internally and therefore serialized ImageIO
encoding even when detached tasks were used.

Crash/recovery still relies on `.writing` queue state and atomic destination
commit. Stop cancels and drains in-flight post-render work before saving the
stopped journal.
