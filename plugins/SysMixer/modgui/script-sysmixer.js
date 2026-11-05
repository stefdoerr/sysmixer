/*
 * System Mixer — modgui controller.
 *
 * 1. The pedal: mute buttons, gain/pan reset, value labels under the knobs,
 *    meters (monitored output ports, see modgui.ttl).
 *
 * 2. Routing, with no MOD-UI changes: "Send to mixer" / "Remove from mixer" in
 *    a right-click menu on any plugin and in the "+" menu, a ✕ per row, and a
 *    pedal that shows only the channels something is connected to.
 *
 * Part 2 goes beyond the official modgui API, which has no menus or
 * connections. It relies on what a MOD-UI page has had for years: the global
 * `desktop`, the [mod-instance] / [mod-port] attributes, cables living inside
 * the input they plug into with data('origin') pointing at their output, the
 * pedalboard's connectionManager, and the /effect/connect|disconnect endpoints
 * the UI itself uses. Where MOD-UI opens a plugin menu of its own (starless), the
 * mixer's entries join it instead of opening a second menu. On starless it also
 * calls toggleTeleport so a send shows
 * as a named teleport instead of a cable across the board. Whatever is missing,
 * routing quietly does less; the audio never depends on any of it.
 */

function (event, funcs) {

    var MIN_DB = -60, MAX_DB = 12, CHANNELS = 16;
    var PLAYBACK = ['/graph/playback_1', '/graph/playback_2'];
    var SEND_TIMEOUT = 10000;   // ms a send waits for its cables to show up

    // Tiny labels under the knobs: "-inf" / "+3.5" dB, "C" / "L40" / "R100".
    function fmt(sym, v) {
        if (sym.indexOf('pan') === 0) {
            var pct = Math.round(Math.abs(v) * 100);
            return pct === 0 ? 'C' : (v < 0 ? 'L' : 'R') + pct;
        }
        if (v <= MIN_DB) return '-inf';
        return (v > 0 ? '+' : '') + v.toFixed(1);
    }
    function isKnob(sym) { return /^(gain\d+|pan\d+|master)$/.test(sym); }

    if (event.type === 'start') {
        var icon = event.icon;

        icon.find('.mx-mute').on('click', function (e) {
            e.stopPropagation();
            var el = $(this);
            var on = !el.hasClass('on');
            el.toggleClass('on', on);
            funcs.set_port_value(el.attr('mx-symbol'), on ? 1 : 0);
        });

        // Reset gain + pan of one row. set_port_value moves the knob but
        // fires no 'change' back to us, so refresh the labels here.
        icon.find('.mx-reset').on('click', function (e) {
            e.stopPropagation();
            var ch = $(this).attr('mx-channel');
            var defs = [['gain' + ch, 0], ['pan' + ch, 0]];
            for (var j = 0; j < defs.length; j++) {
                funcs.set_port_value(defs[j][0], defs[j][1]);
                icon.find('[mx-symbol="' + defs[j][0] + '"]').text(fmt(defs[j][0], defs[j][1]));
            }
        });

        // Initial values for ports already set (pedalboard load / preset).
        var ports = event.ports || [];
        for (var i = 0; i < ports.length; i++) {
            var s = ports[i].symbol, el0 = icon.find('[mx-symbol="' + s + '"]');
            if (/^mute\d+$/.test(s))
                el0.toggleClass('on', ports[i].value > 0.5);
            else if (isKnob(s))
                el0.text(fmt(s, ports[i].value));
        }

        setupRouting(icon, event.data);
        return;
    }

    if (event.type === 'change') {
        var sym = event.symbol;
        var el = event.icon.find('[mx-symbol="' + sym + '"]');
        if (!el.length)
            return;

        if (isKnob(sym)) {
            el.text(fmt(sym, event.value));
        } else if (sym.indexOf('level') === 0) {
            var frac = (event.value - MIN_DB) / (MAX_DB - MIN_DB);
            frac = Math.max(0, Math.min(1, frac));
            el.css('width', ((1 - frac) * 100).toFixed(1) + '%');
        } else if (sym.indexOf('mute') === 0) {
            el.toggleClass('on', event.value > 0.5);
        }
        return;
    }

    if (event.type === 'end') {
        var d = event.data;
        if (d && d.ns) {
            d.pb.off(d.ns);
            $(document).off(d.ns);
            $('.sysmixer-menu').remove();
            if (d.observer) d.observer.disconnect();
        }
        return;
    }

    // ------------------------------------------------------------------ routing

    function setupRouting(icon, d) {
        var pb = (typeof desktop !== 'undefined' && desktop && desktop.pedalboard) || null;
        var me = icon.attr('mod-instance');
        if (!pb || !pb.length || !me)
            return;   // not on a live pedalboard page: the pedal still works, routing does not

        d.pb = pb;
        d.ns = '.sysmixer_' + me.replace(/[^A-Za-z0-9_]/g, '_');
        d.sends = [];      // sends waiting for their cables: [{ pairs: [{from, to}], at, ch }]
        d.layout = null;   // signature of the last applied layout

        var pedal = icon.find('.sysmixer-pedal');

        // A pedalboard method that may not exist here (toggleTeleport is
        // starless-only); MOD-UI throws on unknown methods.
        function call(method) {
            try { return pb.pedalboard.apply(pb, arguments); } catch (e) { return undefined; }
        }
        function request(kind, from, to) {
            $.ajax({ url: '/effect/' + kind + '/' + from + ',' + to, cache: false, dataType: 'json' });
        }
        function notify(text) {
            if (typeof Notification === 'function') { try { new Notification('warn', text); return; } catch (e) {} }
            window.alert(text);
        }

        function inputEl(ch, right) {
            return icon.find('[mod-role=input-audio-port][mod-port-symbol="lv2_in' + ch + (right ? '_r' : '_l') + '"]');
        }
        // Cables plugged into one of our inputs (MOD-UI moves a connected jack into its input).
        function cablesIn(input) {
            return input.find('[mod-role=output-jack]');
        }
        function originOf(cable) {
            var o = $(cable).data('origin');
            return o && o.length ? o : null;
        }
        // A plugin's audio outputs on the board, at most a stereo pair.
        function audioOutputs(pluginEl) {
            return pluginEl.find('[mod-role=output-audio-port][mod-port]').slice(0, 2);
        }
        function pluginEl(instance) {
            return pb.find('[mod-instance="' + instance + '"]').first();
        }
        function nameOf(output) {
            var name = call('teleportPluginName', output);
            if (name) return name;
            var gui = call('getGui', output.data('instance'));
            name = gui && (gui.label || (gui.effect && gui.effect.label));
            return name || String(output.attr('mod-port') || '').split('/').slice(-2, -1)[0] || '?';
        }

        // Channel a plugin feeds, read off our inputs' cables; 0 if none.
        function channelOf(instance) {
            for (var ch = 1; ch <= CHANNELS; ch++) {
                var found = false;
                cablesIn(inputEl(ch, false).add(inputEl(ch, true))).each(function () {
                    var o = originOf(this);
                    if (o && o.data('instance') === instance) found = true;
                });
                if (found) return ch;
            }
            return 0;
        }
        function channelUsed(ch) {
            return cablesIn(inputEl(ch, false)).length + cablesIn(inputEl(ch, true)).length > 0;
        }
        function freeChannel() {
            var now = Date.now();
            for (var ch = 1; ch <= CHANNELS; ch++) {
                var reserved = d.sends.some(function (s) { return s.ch === ch && now - s.at < SEND_TIMEOUT; });
                if (!channelUsed(ch) && !reserved) return ch;
            }
            return 0;
        }

        // The mixer's own outputs go to the system outputs the first time it is used.
        function connectOwnOutputs() {
            var outs = icon.find('[mod-role=output-audio-port][mod-port]');
            if (outs.filter('.output-connected').length) return;
            outs.slice(0, 2).each(function (i) { request('connect', $(this).attr('mod-port'), PLAYBACK[i]); });
        }

        function send(instance) {
            var outs = audioOutputs(pluginEl(instance));
            if (!outs.length || channelOf(instance)) return;
            var ch = freeChannel();
            if (!ch) { notify('The System Mixer is full (' + CHANNELS + ' channels).'); return; }
            connectOwnOutputs();
            var conns = (pb.data('connectionManager') || {}).origIndex || {};
            var pairs = [];
            outs.each(function (i) {
                var from = $(this).attr('mod-port');
                var to = me + '/lv2_in' + ch + (i ? '_r' : '_l');   // mono: L only, the mixer plays it as mono
                for (var target in (conns[from] || {})) {
                    if (PLAYBACK.indexOf(target) >= 0) request('disconnect', from, target);
                }
                request('connect', from, to);
                pairs.push({ from: from, to: to });
            });
            d.sends.push({ pairs: pairs, at: Date.now(), ch: ch });
        }

        // Unplugs the cables into our inputs that `accept(origin, ch)` picks. Nothing is
        // connected anywhere else: taking a plugin out of the mixer leaves it unplugged.
        function unplug(accept) {
            for (var ch = 1; ch <= CHANNELS; ch++) {
                [inputEl(ch, false), inputEl(ch, true)].forEach(function (input) {
                    cablesIn(input).each(function () {
                        var o = originOf(this);
                        if (o && accept(o, ch)) request('disconnect', o.attr('mod-port'), input.attr('mod-port'));
                    });
                });
            }
        }
        // "Remove from mixer" on a plugin
        function unsend(instance) {
            unplug(function (o) { return o.data('instance') === instance; });
        }
        // ✕ on a row: whatever feeds that channel
        function unsendChannel(ch) {
            unplug(function (o, c) { return c === ch; });
        }

        // Teleport a send once all its cables exist, and only sends we made:
        // a send you later turn back into a cable stays a cable.
        function teleportArrived() {
            var now = Date.now();
            d.sends = d.sends.filter(function (s) {
                var jacks = [];
                s.pairs.forEach(function (p) {
                    cablesIn(icon.find('[mod-role=input-audio-port][mod-port="' + p.to + '"]')).each(function () {
                        var o = originOf(this);
                        if (o && o.attr('mod-port') === p.from) jacks.push($(this));
                    });
                });
                if (jacks.length < s.pairs.length)
                    return now - s.at < SEND_TIMEOUT;   // keep waiting, for a while
                var off = jacks.filter(function (j) { return !j.data('teleported'); });
                if (off.length) call('toggleTeleport', off);
                return false;
            });
        }

        // Show the rows (and jacks) of channels in use, name them, ST/MO by wiring.
        function refresh() {
            var layout = '';
            for (var ch = 1; ch <= CHANNELS; ch++) {
                var l = inputEl(ch, false), r = inputEl(ch, true);
                var nl = cablesIn(l).length, nr = cablesIn(r).length;
                layout += (nl ? 1 : 0) + (nr ? 2 : 0);
            }
            if (layout !== d.layout) {
                d.layout = layout;
                for (ch = 1; ch <= CHANNELS; ch++) {
                    var state = +layout[ch - 1];
                    var row = icon.find('.mx-row[mx-channel="' + ch + '"]');
                    row.toggleClass('mx-used', state > 0);
                    inputEl(ch, false).add(inputEl(ch, true)).toggleClass('mx-hidden', state === 0);
                    row.find('.mx-mode').toggleClass('stereo', state === 3).text(state === 3 ? 'ST' : (state ? 'MO' : ''));
                }
                pedal.toggleClass('mx-empty', !/[1-3]/.test(layout));
                // the jacks moved: redraw every cable on this pedal
                setTimeout(function () { call('drawPluginJacks', icon); }, 0);
            }
            // names can change without the layout changing (a re-send, a rename)
            for (ch = 1; ch <= CHANNELS; ch++) {
                var o = null;
                cablesIn(inputEl(ch, false).add(inputEl(ch, true))).each(function () { o = o || originOf(this); });
                var nameEl = icon.find('.mx-row[mx-channel="' + ch + '"] .mx-name');
                var name = o ? nameOf(o) : '';
                if (nameEl.text() !== name) nameEl.text(name);
            }
            teleportArrived();
        }

        // Cables come and go as jacks moving in and out of our inputs.
        var pending = false;
        function schedule() {
            if (pending) return;
            pending = true;
            setTimeout(function () { pending = false; refresh(); }, 0);
        }
        var inputs = icon.find('.mod-pedal-input')[0];
        if (inputs && typeof MutationObserver === 'function') {
            d.observer = new MutationObserver(schedule);
            d.observer.observe(inputs, { childList: true, subtree: true });
        }
        refresh();

        // -------------------------------------------------------------- menus

        function showMenu(x, y, items) {
            $('.sysmixer-menu').remove();
            var menu = $('<div class="sysmixer-menu">').css({ left: x, top: y }).appendTo('body');
            var close = function () {
                menu.remove();
                $(document).off('mousedown' + d.ns + ' keydown' + d.ns + ' wheel' + d.ns);
            };
            if (!items.length)
                $('<div class="sysmixer-menu-empty">').text('No plugins left to send').appendTo(menu);
            items.forEach(function (it) {
                $('<div>').text(it[0]).appendTo(menu).on('click', function (e) {
                    e.stopPropagation();
                    close();
                    it[1]();
                });
            });
            menu.on('mousedown', function (e) { e.stopPropagation(); });
            $(document).on('mousedown' + d.ns + ' keydown' + d.ns + ' wheel' + d.ns, close);
        }

        // Only one mixer answers right-clicks: the first on the board.
        function ownsMenu() {
            return pb.find('.sysmixer-pedal').first().closest('[mod-instance]').attr('mod-instance') === me;
        }

        function menuItems(instance) {
            var ch = channelOf(instance);
            return ch
                ? [['Remove from mixer (channel ' + ch + ')', function () { unsend(instance); }]]
                : [['Send to mixer', function () { send(instance); }]];
        }

        // Our items as a group inside a plugin menu MOD-UI itself opened (starless):
        // right after the plugin's first group (Settings / Info / Bypass), styled and
        // closed the way that menu's own rows are.
        function joinMenu(menu, items) {
            var close = function () {
                menu.remove();
                $(document).off('.portcontextmenu');
            };
            var nodes = [$('<hr class="mod-contextmenu-separator">')];
            items.forEach(function (it) {
                nodes.push($('<div>').text(it[0]).on('click', function (e) {
                    e.stopPropagation();
                    close();
                    it[1]();
                }));
            });
            var firstBreak = menu.children('hr').first();
            if (firstBreak.length) firstBreak.before(nodes);
            else menu.append(nodes);
        }

        // Right-click a plugin. A port menu (ports with cables) runs first and stops the
        // event, so this only sees plugin bodies and free ports. If MOD-UI opened a
        // plugin menu of its own for this click, we join it; otherwise we open ours.
        // Decided a tick later, so it does not matter which handler MOD-UI runs first.
        pb.on('contextmenu' + d.ns, '[mod-instance]', function (e) {
            if (!ownsMenu()) return;
            var instance = $(this).attr('mod-instance');
            if (instance === me || !audioOutputs($(this)).length) return;
            e.preventDefault();
            var x = e.clientX, y = e.clientY;
            setTimeout(function () {
                var theirs = $('.mod-port-contextmenu');
                if (theirs.length) joinMenu(theirs.last(), menuItems(instance));
                else showMenu(x, y, menuItems(instance));
            }, 0);
        });

        // "+": every plugin with audio outputs not yet in the mixer.
        icon.find('.mx-add').on('mousedown', function (e) { e.stopPropagation(); }).on('click', function (e) {
            e.stopPropagation();
            var items = [];
            pb.find('[mod-instance]').each(function () {
                var instance = $(this).attr('mod-instance');
                var outs = audioOutputs($(this));
                if (instance === me || !outs.length || channelOf(instance)) return;
                items.push([nameOf(outs.first()), function () { send(instance); }]);
            });
            items.sort(function (a, b) { return a[0].localeCompare(b[0], undefined, { numeric: true }); });
            var r = this.getBoundingClientRect();
            showMenu(r.left, r.bottom + 4, items);
        });

        icon.find('.mx-unsend').on('mousedown', function (e) { e.stopPropagation(); }).on('click', function (e) {
            e.stopPropagation();
            unsendChannel(+$(this).attr('mx-channel'));
        });
    }
}
