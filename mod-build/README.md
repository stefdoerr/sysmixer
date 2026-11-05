# Cross-build for MOD Dwarf

Everything needed to cross-compile this plugin to an aarch64 `.lv2`
bundle that runs on the MOD Dwarf. **Self-contained**: only host
dependency is Docker.

## Files

- **`Dockerfile`** — vendored from `moddevices/mod-plugin-builder`,
  hard-locked to `moddwarf-new`. Builds a Debian Bookworm image and
  inside it clones MPB + runs its bootstrap to produce a buildroot
  aarch64 cross-toolchain (glibc 2.27, gcc 9.4.0 — matching Dwarf
  firmware).
- **`build-plugin.sh`** — runs inside the container. Native (x86_64)
  build to produce DPF's introspected `.ttl` metadata + modgui assets,
  then a cross-build of the `.so`, then assembles the final aarch64
  bundle into `/out`.

## One-time setup

```bash
make dwarf-image          # ~30-60 min, cached forever after
```

Most of the time is MPB's bootstrap compiling the cross-toolchain via
crosstool-ng. After this completes, every cross-build is ~10s.

## Daily workflow

```bash
make dwarf-build          # build/dwarf/<plugin>.lv2 (aarch64)
make dwarf-deploy         # scp to a connected Dwarf at 192.168.51.1
make dwarf                # both
```

Override defaults on the command line:

| Variable        | Default          | Purpose |
|-----------------|------------------|---------|
| `CROSS_IMAGE`   | `moddwarf-cross` | Docker image tag. Plugin-independent: shared by every plugin built from the template, so the ~6 GB toolchain is built once per machine, not once per plugin. |
| `DWARF_HOST`    | `192.168.51.1`   | Hostname/IP of the connected Dwarf. |
| `DWARF_USER`    | `root`           | SSH user on the Dwarf. |
| `DWARF_LV2DIR`  | `/root/.lv2`     | Plugin install dir on the Dwarf. |

## Why two builds (native + cross)?

DPF's `lv2_ttl_generator` is a helper that `dlopen()`s the plugin to
introspect its ports and emit `manifest.ttl` / `<plugin>.ttl`. It has to
run on the same architecture as the plugin. Inside the container we have
a native x86_64 toolchain (from Debian) *and* an aarch64 cross-toolchain
(from MPB). The native one generates the TTLs, then we swap in the
cross-built `.so` to assemble the aarch64 bundle.

## Resyncing with upstream MPB

`Dockerfile` is a near-verbatim copy of
`moddevices/mod-plugin-builder/docker/Dockerfile`. If upstream MPB
changes the bootstrap, `diff` against the upstream file and cherry-pick.
The platform-specific `if test ...` blocks have been collapsed here; if
you ever need to target `modduo` or `modduox`, restore them from
upstream.

## Troubleshooting

- **`docker build` fails with apt errors**: try `--network=host`:
  `docker build --network=host -t moddwarf-cross mod-build/`
- **Image build runs out of disk**: the toolchain + buildroot tree is
  ~10 GB. Free up at least 15 GB before starting.
- **`build-plugin.sh` complains the cross-toolchain is missing**: the
  image was built but MPB's bootstrap didn't complete. Rebuild with
  `docker build --no-cache -t moddwarf-cross mod-build/`.
- **Deployed but the plugin still looks old in MOD-UI**: two
  independent lilv caches on the Dwarf. `dwarf-deploy` restarts both
  `jack2` and `mod-ui` — if you deploy manually with `scp`, you have to
  restart both. Then hard-refresh the browser tab (Ctrl-Shift-R) so
  MOD-UI's JS-side plugin metadata isn't served from the browser cache.
