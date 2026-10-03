# Contributing

Issues and pull requests are welcome. A few things that make them land:

- **Say what you ran on.** Mac model, macOS version, `runtime/pin.txt`,
  the output of `kdevm.sh status`, and for guest problems the versions from
  `~/.cache/kdevm/factory-info.txt`. The stack has a lot of moving parts and
  the provenance usually decides the question.
- **Reproduce with the verbs.** `kdevm.sh destroy --all`, then `factory`,
  `preflight`, `up`. The preflight prints a verdict that separates the GPU
  stack (QEMU, VirGL, Mesa) from the session (KWin, KScreen, Plasma); quote
  it.
- **Keep the runtime build theirs.** `runtime/build.sh` runs try-omarchy's
  build script unchanged apart from the product-name string. If you need a
  different QEMU patch, propose it upstream at
  [omacom/try-omarchy](https://github.com/omacom/try-omarchy) first; kdevm
  tracks their pin.
- **Measure before and after.** Idle CPU and footprint with try-omarchy's
  `scripts/profile-process.py` (it checks the VM is actually running through
  QMP), boot time with `up` to a Wayland socket. Numbers go in
  `docs/runbook.md` with the date and the hardware.
- **Guest changes go in the cloud-init template** (`guest/user-data.yaml.tmpl`)
  or `guest/files/`, never by hand in a running overlay: the factory is the
  source of truth and a `rebuild` must reproduce the fix.
- Run `tests/checks.sh` before pushing. It is offline (no VM, no real
  state touched) and covers syntax, password generation, the overlay guard,
  stale-pid safety, locking, permissions and YAML rendering. The YAML probe
  wants `python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt`.
- Shell is zsh on macOS, bash inside the guest. No em dashes in prose.
