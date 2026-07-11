---
name: Bug / reproduction report
about: Report a problem building or running PACT, or reproducing a result
title: ""
labels: bug
---

**What happened**
A clear description of the problem and what you expected instead.

**How to reproduce**
The exact command(s) you ran (workload, PACT flags, or the figure/experiment).

**Environment**
- PACT version: (`./src/pact --version`)
- CPU model: (`lscpu | grep 'Model name'`)
- Kernel: (`uname -r`)
- NUMA topology: (`numactl -H` — node sizes and which nodes have CPUs)
- Fast-tier setup: (`memmap=` value / node 0 size, if running the tiering flow)

**Logs**
Attach the relevant output, e.g. `run/results/<workload>/pact/pact_debug.log`
and `workload.output`, or the build log.
