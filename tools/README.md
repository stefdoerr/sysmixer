# tools

## lv2bench

Times an installed LV2 plugin's `run()` on the machine it runs on, so plugins
can be compared under identical conditions (the CPU table in the main README
comes from it). Any LV2 plugin works, not just this one.

Cross-compile for the Dwarf with the same toolchain image as `make dwarf`:

```bash
docker run --rm -v "$PWD/tools:/t" moddwarf-cross bash -c '
  B=/root/mod-workdir/moddwarf-new/host/usr/bin
  R=/root/mod-workdir/moddwarf-new/host/usr/aarch64-buildroot-linux-gnu/sysroot
  $B/aarch64-modaudio-linux-gnu-gcc -O2 -Wall -std=gnu11 -I$R/usr/include/lilv-0 \
      -o /t/lv2bench.aarch64 /t/lv2bench.c -llilv-0 -lm'
scp -O tools/lv2bench.aarch64 root@192.168.51.1:/tmp/lv2bench
```

Run it on the Dwarf (`LV2_PATH` limited to the bundles you compare, so loading
is quick):

```bash
mkdir -p /tmp/benchlv2 && ln -sf /root/.lv2/sysmixer.lv2 /tmp/benchlv2/
LV2_PATH=/tmp/benchlv2 /tmp/lv2bench http://stefan.local/plugins/sysmixer all 20000 128 48000 3
#                                    plugin URI                  fed inputs blocks frames rate cpu
```

It prints mean, median, p99 and max microseconds per block. Compare medians:
the tails pick up whatever else the device is doing (a running pedalboard on
the same core shows up there for every plugin alike).
