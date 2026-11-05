/*
 * SysMixer — DPF plugin info header.
 *
 * BETA build: pass -DSYSMIXER_BETA (top-level Makefile does this when
 * BETA=1) for a side-by-side build with a distinct URI / name / unique-id.
 */

#ifndef DISTRHO_PLUGIN_INFO_H_INCLUDED
#define DISTRHO_PLUGIN_INFO_H_INCLUDED

#ifdef SYSMIXER_BETA
#define DISTRHO_PLUGIN_BRAND   "Stefan"
#define DISTRHO_PLUGIN_NAME    "System Mixer (Beta)"
#define DISTRHO_PLUGIN_URI     "http://stefan.local/plugins/sysmixer-beta"
#define DISTRHO_PLUGIN_CLAP_ID "local.stefan.sysmixer-beta"
#define DISTRHO_PLUGIN_BRAND_ID  StfB
#define DISTRHO_PLUGIN_UNIQUE_ID sSMB
#else
#define DISTRHO_PLUGIN_BRAND   "Stefan"
#define DISTRHO_PLUGIN_NAME    "System Mixer"
#define DISTRHO_PLUGIN_URI     "http://stefan.local/plugins/sysmixer"
#define DISTRHO_PLUGIN_CLAP_ID "local.stefan.sysmixer"
#define DISTRHO_PLUGIN_BRAND_ID  Stfn
#define DISTRHO_PLUGIN_UNIQUE_ID sSMx
#endif

#define PLUGIN_HOMEPAGE "https://github.com/stefdoerr/sysmixer"

#define DISTRHO_PLUGIN_LV2_CATEGORY   "lv2:MixerPlugin"

#define DISTRHO_PLUGIN_HAS_UI         0    // modgui supplies the GUI on MOD
#define DISTRHO_PLUGIN_IS_RT_SAFE     1
#define DISTRHO_PLUGIN_NUM_INPUTS     32   // 16 stereo channels (L,R pairs)
#define DISTRHO_PLUGIN_NUM_OUTPUTS    2

#define DISTRHO_PLUGIN_WANT_PROGRAMS                          0
#define DISTRHO_PLUGIN_WANT_STATE                             0
#define DISTRHO_PLUGIN_WANT_PARAMETER_VALUE_CHANGE_REQUEST    0

#endif // DISTRHO_PLUGIN_INFO_H_INCLUDED
