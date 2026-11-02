#!/usr/bin/env bash
# retry.sh <command>...: runs the command up to five times until it succeeds.
# Zig's downloads of dependencies from GitHub fail now and then (the
# connection closes), lazy ones included, which builds fetch as they need
# them; what was fetched stays in the cache, so a retry gets further.
for attempt in 1 2 3 4 5; do
  "$@" && exit 0
  echo "retry.sh: attempt $attempt failed: $*" >&2
  sleep 15
done
exit 1
