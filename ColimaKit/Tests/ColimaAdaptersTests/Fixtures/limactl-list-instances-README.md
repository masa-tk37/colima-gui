# limactl-list-instances.ndjson

Hand-built from the field shapes of `limactl list --json` (Lima 2.3.0, `pkg/limatype/lima_instance.go`)
and one real `LIMA_HOME=~/.colima/_lima limactl list --json` row. No `cg-` instance existed on the machine
when this was written. Refresh it from a real run in the manual verification task (tasks.md 9.3).
Rows cover: running, stopped, broken, no `config`, an undecodable owned row, an installing row,
unmarked prefixed names (`cg-Manual`, `CG-Upper`), an unprefixed name, and a row without `name`.
