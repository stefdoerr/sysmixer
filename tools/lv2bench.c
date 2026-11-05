/*
 * lv2bench -- time an installed LV2 plugin's run() on the machine it runs on.
 *
 *   lv2bench <plugin-uri> [fed-audio-inputs|all] [blocks] [frames] [rate] [cpu]
 *
 * Loads the plugin with lilv from LV2_PATH, connects every port (control inputs
 * at their defaults, the first N audio inputs fed with noise and the rest
 * silent, atom ports with empty sequences), runs blocks back to back and
 * prints the cost per block as mean / median / p99 / max microseconds and as a
 * share of the audio period. Meant for comparing plugins on a MOD Dwarf under
 * identical conditions; build it with the cross toolchain (see tools/README).
 */

#define _GNU_SOURCE
#include <lilv/lilv.h>
#include "lv2/lv2plug.in/ns/ext/atom/atom.h"
#include "lv2/lv2plug.in/ns/ext/buf-size/buf-size.h"
#include "lv2/lv2plug.in/ns/ext/options/options.h"
#include "lv2/lv2plug.in/ns/ext/parameters/parameters.h"
#include "lv2/lv2plug.in/ns/ext/urid/urid.h"

#include <math.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* ---- urid map: a plain string table is plenty for one plugin ---- */
static char *uris[512];
static uint32_t nuris = 0;

static LV2_URID map_uri(LV2_URID_Map_Handle h, const char *uri)
{
    (void)h;
    for (uint32_t i = 0; i < nuris; ++i)
        if (!strcmp(uris[i], uri)) return i + 1;
    if (nuris == 512) return 0;
    uris[nuris] = strdup(uri);
    return ++nuris;
}

static const char *unmap_uri(LV2_URID_Unmap_Handle h, LV2_URID u)
{
    (void)h;
    return (u && u <= nuris) ? uris[u - 1] : NULL;
}

static int cmp_double(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

static double now_us(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e6 + t.tv_nsec / 1e3;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <plugin-uri> [fed-audio-inputs|all] [blocks] [frames] [rate] [cpu]\n", argv[0]);
        return 2;
    }
    const char *uri    = argv[1];
    int fed            = (argc > 2 && strcmp(argv[2], "all")) ? atoi(argv[2]) : -1;
    int blocks         = argc > 3 ? atoi(argv[3]) : 20000;
    int32_t frames     = argc > 4 ? atoi(argv[4]) : 128;
    float rate         = argc > 5 ? (float)atof(argv[5]) : 48000.0f;
    int cpu            = argc > 6 ? atoi(argv[6]) : -1;

    if (cpu >= 0) {
        cpu_set_t set;
        CPU_ZERO(&set);
        CPU_SET(cpu, &set);
        if (sched_setaffinity(0, sizeof(set), &set))
            perror("sched_setaffinity");
    }

    LilvWorld *world = lilv_world_new();
    lilv_world_load_all(world);
    LilvNode *uri_node = lilv_new_uri(world, uri);
    const LilvPlugin *plugin = lilv_plugins_get_by_uri(lilv_world_get_all_plugins(world), uri_node);
    if (!plugin) {
        fprintf(stderr, "plugin not found: %s\n", uri);
        return 1;
    }

    /* features DPF plugins insist on: urid map/unmap and options with block sizes */
    LV2_URID_Map map = { NULL, map_uri };
    LV2_URID_Unmap unmap = { NULL, unmap_uri };
    int32_t min_len = 0, max_len = frames, nom_len = frames;
    LV2_URID t_int = map_uri(NULL, LV2_ATOM__Int), t_float = map_uri(NULL, LV2_ATOM__Float);
    LV2_Options_Option opts[] = {
        { LV2_OPTIONS_INSTANCE, 0, map_uri(NULL, LV2_BUF_SIZE__minBlockLength), sizeof(int32_t), t_int, &min_len },
        { LV2_OPTIONS_INSTANCE, 0, map_uri(NULL, LV2_BUF_SIZE__maxBlockLength), sizeof(int32_t), t_int, &max_len },
        { LV2_OPTIONS_INSTANCE, 0, map_uri(NULL, LV2_BUF_SIZE__nominalBlockLength), sizeof(int32_t), t_int, &nom_len },
        { LV2_OPTIONS_INSTANCE, 0, map_uri(NULL, LV2_PARAMETERS__sampleRate), sizeof(float), t_float, &rate },
        { LV2_OPTIONS_INSTANCE, 0, 0, 0, 0, NULL },
    };
    LV2_Feature f_map = { LV2_URID__map, &map }, f_unmap = { LV2_URID__unmap, &unmap };
    LV2_Feature f_opts = { LV2_OPTIONS__options, opts };
    LV2_Feature f_bounded = { LV2_BUF_SIZE__boundedBlockLength, NULL };
    const LV2_Feature *features[] = { &f_map, &f_unmap, &f_opts, &f_bounded, NULL };

    LilvInstance *inst = lilv_plugin_instantiate(plugin, rate, features);
    if (!inst) {
        fprintf(stderr, "instantiate failed: %s\n", uri);
        return 1;
    }

    LilvNode *c_audio = lilv_new_uri(world, LILV_URI_AUDIO_PORT);
    LilvNode *c_cv = lilv_new_uri(world, LILV_URI_CV_PORT);
    LilvNode *c_control = lilv_new_uri(world, LILV_URI_CONTROL_PORT);
    LilvNode *c_atom = lilv_new_uri(world, LV2_ATOM__AtomPort);
    LilvNode *c_input = lilv_new_uri(world, LILV_URI_INPUT_PORT);

    uint32_t nports = lilv_plugin_get_num_ports(plugin);
    float *mins = calloc(nports, sizeof(float)), *maxs = calloc(nports, sizeof(float)), *defs = calloc(nports, sizeof(float));
    lilv_plugin_get_port_ranges_float(plugin, mins, maxs, defs);
    float *controls = calloc(nports, sizeof(float));
    void **bufs = calloc(nports, sizeof(void *));
    const uint32_t atom_cap = 8192;
    LV2_URID t_seq = map_uri(NULL, LV2_ATOM__Sequence), t_chunk = map_uri(NULL, LV2_ATOM__Chunk);

    int audio_in = 0, audio_out = 0, fed_count = 0;
    uint32_t seed = 12345;
    for (uint32_t i = 0; i < nports; ++i) {
        const LilvPort *port = lilv_plugin_get_port_by_index(plugin, i);
        int is_in = lilv_port_is_a(plugin, port, c_input);
        if (lilv_port_is_a(plugin, port, c_audio) || lilv_port_is_a(plugin, port, c_cv)) {
            float *b = calloc(frames, sizeof(float));
            if (is_in) {
                if (fed < 0 || audio_in < fed) {
                    for (int f = 0; f < frames; ++f) {   /* fixed noise, -12 dBFS-ish */
                        seed = seed * 1664525u + 1013904223u;
                        b[f] = ((seed >> 8) / 16777216.0f - 0.5f) * 0.5f;
                    }
                    ++fed_count;
                }
                ++audio_in;
            } else {
                ++audio_out;
            }
            bufs[i] = b;
            lilv_instance_connect_port(inst, i, b);
        } else if (lilv_port_is_a(plugin, port, c_control)) {
            float v = defs[i];
            if (isnan(v)) v = isnan(mins[i]) ? 0.0f : mins[i];
            controls[i] = v;
            lilv_instance_connect_port(inst, i, &controls[i]);
        } else if (lilv_port_is_a(plugin, port, c_atom)) {
            LV2_Atom_Sequence *seq = calloc(1, atom_cap);
            bufs[i] = seq;
            lilv_instance_connect_port(inst, i, seq);
        } else {
            lilv_instance_connect_port(inst, i, NULL);
        }
    }

    lilv_instance_activate(inst);

    double *t = malloc(sizeof(double) * blocks);
    for (int b = -500; b < blocks; ++b) {          /* 500 warm-up blocks, not timed */
        for (uint32_t i = 0; i < nports; ++i) {
            const LilvPort *port = lilv_plugin_get_port_by_index(plugin, i);
            if (bufs[i] && lilv_port_is_a(plugin, port, c_atom)) {
                LV2_Atom_Sequence *seq = bufs[i];
                if (lilv_port_is_a(plugin, port, c_input)) {
                    seq->atom.size = sizeof(LV2_Atom_Sequence_Body);
                    seq->atom.type = t_seq;
                } else {
                    seq->atom.size = atom_cap - sizeof(LV2_Atom);
                    seq->atom.type = t_chunk;
                }
                seq->body.unit = 0;
                seq->body.pad = 0;
            }
        }
        double t0 = now_us();
        lilv_instance_run(inst, frames);
        double dt = now_us() - t0;
        if (b >= 0) t[b] = dt;
    }

    lilv_instance_deactivate(inst);

    double sum = 0;
    for (int b = 0; b < blocks; ++b) sum += t[b];
    qsort(t, blocks, sizeof(double), cmp_double);
    double period = frames * 1e6 / rate;
    double mean = sum / blocks;
    printf("%-48s in %2d (fed %2d) out %2d | mean %7.2f us  median %7.2f  p99 %7.2f  max %8.2f | mean %5.2f%% of %.0f us period\n",
           uri, audio_in, fed_count, audio_out, mean, t[blocks / 2], t[(int)(blocks * 0.99)], t[blocks - 1],
           100.0 * mean / period, period);

    lilv_instance_free(inst);
    lilv_world_free(world);
    return 0;
}
