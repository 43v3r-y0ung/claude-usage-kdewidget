import QtQuick
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

import "../code/format.js" as Format

PlasmoidItem {
    id: root

    // Last document printed by code/fetch_usage.py; see that file for its fields.
    property var usage: null
    property bool loading: false
    // Ticks every 30 s so the countdowns move without asking the server.
    property double now: Date.now()

    readonly property var limits: usage ? usage.limits : []
    readonly property var panelLimit: Format.pickLimit(limits, Plasmoid.configuration.panelLimit)
    readonly property bool hasData: limits.length > 0

    // Limits whose reset time has passed are shown as empty until the next fetch.
    function percentOf(limit) {
        return limit && Format.secondsUntil(limit.resets_at, now) > 0 ? limit.percent : 0;
    }
    function colorFor(percent) {
        if (percent >= Plasmoid.configuration.criticalPercent)
            return Kirigami.Theme.negativeTextColor;
        if (percent >= Plasmoid.configuration.warningPercent)
            return Kirigami.Theme.neutralTextColor;
        return Kirigami.Theme.highlightColor;
    }
    function resetText(limit) {
        const s = Format.secondsUntil(limit.resets_at, now);
        if (isNaN(s))
            return "";
        if (s <= 0)
            return i18n("Reset, refreshing…");
        const at = Qt.locale().toString(new Date(limit.resets_at), s < 86400 ? "HH:mm" : "ddd HH:mm");
        return i18n("Resets in %1 (%2)", Format.duration(s), at);
    }

    readonly property string _script: decodeURIComponent(Qt.resolvedUrl("../code/fetch_usage.py").toString().replace(/^file:\/\//, ""))
    function _quote(s) {
        return "'" + s.replace(/'/g, "'\\''") + "'";
    }
    function refresh(force, maxAge) {
        let cmd = "/usr/bin/python3 -I " + _quote(_script)
            + " --max-age " + (maxAge || Math.max(30, Plasmoid.configuration.refreshMinutes * 60 - 20));
        if (force)
            cmd += " --force";
        if (Plasmoid.configuration.allowTokenRefresh)
            cmd += " --allow-refresh";
        if (Plasmoid.configuration.configDir)
            cmd += " --config-dir " + _quote(Plasmoid.configuration.configDir);
        loading = true;
        runner.connectSource(cmd);
    }

    // Token totals of one period, printed by code/token_stats.py.
    property var tokens: null
    property int tokenOffset: 0
    property int _tokenTag: 0
    readonly property string tokenPeriod: Plasmoid.configuration.tokenPeriod
    readonly property bool darkTheme: Kirigami.ColorUtils.brightnessForColor(Kirigami.Theme.backgroundColor) === Kirigami.ColorUtils.Dark

    // Fixed categorical order, validated for both themes; a model keeps its slot
    // (by all-time use) whatever period is shown. Past eight it goes grey.
    readonly property var _lightSlots: ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#6250d6", "#e34948"]
    readonly property var _darkSlots: ["#3987e5", "#d95926", "#199e70", "#c98500", "#d55181", "#008300", "#9085e9", "#e66767"]
    function modelColor(slot) {
        const slots = darkTheme ? _darkSlots : _lightSlots;
        return slot >= 0 && slot < slots.length ? slots[slot] : Kirigami.Theme.disabledTextColor;
    }

    readonly property string _tokenScript: decodeURIComponent(Qt.resolvedUrl("../code/token_stats.py").toString().replace(/^file:\/\//, ""))
    function _tokenCommand(args) {
        let cmd = "/usr/bin/python3 -I " + _quote(_tokenScript) + " " + args;
        if (Plasmoid.configuration.configDir)
            cmd += " --config-dir " + _quote(Plasmoid.configuration.configDir);
        return cmd;
    }
    function loadTokens() {
        const session = limits.find(l => l.kind === "session");
        let args = "query --period " + tokenPeriod + " --offset " + tokenOffset + " --tag " + (++_tokenTag);
        if (session && session.resets_at)
            args += " --session-end " + _quote(session.resets_at);
        tokenRunner.connectSource(_tokenCommand(args));
    }
    function setTokenPeriod(period) {
        Plasmoid.configuration.tokenPeriod = period;
        tokenOffset = 0;
        loadTokens();
    }
    function setTokenOffset(offset) {
        tokenOffset = offset;
        loadTokens();
    }
    function moveTokenOffset(delta) {
        tokenOffset = Math.max(0, tokenOffset + delta);
        loadTokens();
    }

    P5Support.DataSource {
        id: tokenRunner
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => {
            disconnectSource(sourceName);
            let answer;
            try {
                answer = JSON.parse(data.stdout);
            } catch (e) {
                console.warn("claudeusage: token helper failed:", data.stderr || e);
                answer = { ok: false, error: i18n("Token history helper failed") };
            }
            // Answers to superseded requests (an older tab or page) are dropped.
            if (answer.tag === undefined || String(answer.tag) === String(root._tokenTag)) {
                // The helper clamps an offset past the oldest session; follow it.
                if (answer.ok && answer.offset !== undefined)
                    root.tokenOffset = answer.offset;
                root.tokens = answer;
            }
        }
    }

    // Live updates: code/watch_activity.py answers when Claude Code writes a
    // transcript (once per step of a response) or a session turns busy or idle.
    readonly property bool liveUpdates: Plasmoid.configuration.liveUpdates
    readonly property int liveFetchSeconds: 60
    property var activeSessions: []
    property var _busy: null
    property int _watchTag: 0
    readonly property string _watchScript: decodeURIComponent(Qt.resolvedUrl("../code/watch_activity.py").toString().replace(/^file:\/\//, ""))
    function watch() {
        let cmd = "/usr/bin/python3 -I " + _quote(_watchScript) + " --tag " + (++_watchTag);
        if (_busy !== null)
            cmd += " --busy " + _quote(_busy.join(","));
        if (Plasmoid.configuration.configDir)
            cmd += " --config-dir " + _quote(Plasmoid.configuration.configDir);
        watchRunner.connectSource(cmd);
    }
    function stopWatching() {
        ++_watchTag;  // a watcher still running is ignored when it answers
        watchRetry.stop();
        liveFetch.stop();
        _busy = null;
        activeSessions = [];
    }

    P5Support.DataSource {
        id: watchRunner
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => {
            disconnectSource(sourceName);
            let answer;
            try {
                answer = JSON.parse(data.stdout);
            } catch (e) {
                answer = { ok: false, error: data.stderr || String(e) };
            }
            if (!root.liveUpdates || String(answer.tag) !== String(root._watchTag))
                return;
            if (!answer.ok) {
                console.warn("claudeusage: activity watcher failed:", answer.error);
                watchRetry.start();
                return;
            }
            const before = root._busy;
            root.activeSessions = answer.sessions;
            root._busy = answer.busy;
            if (answer.reason === "transcripts" && root.expanded)
                root.loadTokens();
            // A response ended, so its usage now counts toward the limits.
            if (before && before.some(id => answer.busy.indexOf(id) < 0) && !liveFetch.running) {
                const age = root.usage && root.usage.fetched_at ? (Date.now() - Date.parse(root.usage.fetched_at)) / 1000 : Infinity;
                liveFetch.interval = Math.max(0, root.liveFetchSeconds - age) * 1000 + 1000;
                liveFetch.start();
            }
            root.watch();
        }
    }
    // Waits out the minimum age of a fetch, so the end of every response is fetched.
    Timer {
        id: liveFetch
        onTriggered: root.refresh(false, root.liveFetchSeconds)
    }
    Timer {
        id: watchRetry
        interval: 60000
        onTriggered: if (root.liveUpdates) root.watch()
    }

    onExpandedChanged: () => {
        if (root.expanded) {
            tokenOffset = 0;
            loadTokens();
        }
    }

    P5Support.DataSource {
        id: runner
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => {
            disconnectSource(sourceName);
            root.loading = false;
            try {
                root.usage = JSON.parse(data.stdout);
            } catch (e) {
                console.warn("claudeusage: helper failed:", data.stderr || e);
                root.usage = Object.assign({}, root.usage || {}, {
                    ok: false,
                    stale: root.hasData,
                    error: i18n("Helper script failed: %1", (data.stderr || String(e)).trim().split("\n").pop())
                });
            }
            root.now = Date.now();
        }
    }

    Timer {
        interval: Plasmoid.configuration.refreshMinutes * 60000
        running: true
        repeat: true
        onTriggered: {
            root.refresh(false);
            // Also while the popup is closed: keeps copying transcripts into the
            // history, and has the numbers ready (at their final height) when it opens.
            root.loadTokens();
        }
    }

    // Refetch once right after a limit resets, so the new window shows up promptly.
    property string _refetchedFor: ""
    Timer {
        interval: 30000
        running: true
        repeat: true
        onTriggered: {
            root.now = Date.now();
            const passed = root.limits.find(l => Format.secondsUntil(l.resets_at, root.now) < -10);
            if (passed && passed.resets_at !== root._refetchedFor && !root.loading) {
                root._refetchedFor = passed.resets_at;
                root.refresh(true);
            }
        }
    }

    Connections {
        target: Plasmoid.configuration
        function onConfigDirChanged() {
            root.refresh(true);
            root.loadTokens();
            if (root.liveUpdates) {
                root.stopWatching();
                root.watch();
            }
        }
        function onAllowTokenRefreshChanged() { root.refresh(true); }
        function onLiveUpdatesChanged() {
            root.stopWatching();
            if (root.liveUpdates)
                root.watch();
        }
    }

    Component.onCompleted: {
        refresh(false);
        loadTokens();
        if (liveUpdates)
            watch();
    }

    // The widget's own icon, shipped in the package (also used by the settings window).
    Plasmoid.icon: Qt.resolvedUrl("../icons/claude-usage.svg").toString().replace(/^file:\/\//, "")
    Plasmoid.status: hasData && percentOf(panelLimit) >= Plasmoid.configuration.criticalPercent
        ? PlasmaCore.Types.NeedsAttentionStatus : PlasmaCore.Types.ActiveStatus

    toolTipMainText: i18n("Claude usage")
    toolTipSubText: {
        if (!hasData)
            return usage && usage.error ? usage.error : i18n("Loading…");
        let lines = limits.map(l => i18n("%1: %2% · %3", l.label, Math.round(percentOf(l)), resetText(l)));
        const working = activeSessions.filter(s => s.busy).length;
        if (working > 0)
            lines.push(i18np("Claude Code is working in 1 session", "Claude Code is working in %1 sessions", working));
        if (usage.error)
            lines.push(usage.error);
        return lines.join("\n");
    }

    compactRepresentation: CompactRepresentation {}
    fullRepresentation: FullRepresentation {}

    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: i18n("Refresh Now")
            icon.name: "view-refresh"
            onTriggered: root.refresh(true)
        }
    ]
}
