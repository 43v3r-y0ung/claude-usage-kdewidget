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

    // Templates for Format.duration. "%1" and "%2" are passed through untouched for format.js to fill in.
    readonly property var durationUnits: ({
        now: i18nc("@item:intext a duration under a minute", "now"),
        m: i18nc("@item:intext short duration in minutes", "%1m", "%1"),
        hm: i18nc("@item:intext short duration in hours and minutes", "%1h %2m", "%1", "%2"),
        dh: i18nc("@item:intext short duration in days and hours", "%1d %2h", "%1", "%2")
    })

    readonly property var limits: usage ? usage.limits : []
    readonly property var panelLimit: Format.pickLimit(limits, Plasmoid.configuration.panelLimit)
    readonly property bool hasData: limits.length > 0
    // Modes 3 and 4 show the weekly and session limits as nested rings:
    // 3 has the weekly one outside, 4 the session one.
    readonly property bool nestedRings: Plasmoid.configuration.panelLimit >= 3
    readonly property bool sessionOutside: Plasmoid.configuration.panelLimit === 4
    readonly property var weeklyLimit: nestedRings ? Format.pickLimit(limits, 1) : null

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
        return i18n("Resets in %1 (%2)", Format.duration(s, root.durationUnits), at);
    }

    // fetch_usage.py writes its labels and errors in English; these are the translated ones.
    function limitLabel(limit) {
        switch (limit.kind) {
        case "session": return i18n("Session (5h)");
        case "weekly_all": return i18n("Weekly · all models");
        case "weekly_scoped": {
            const model = limit.label.replace(/^Weekly · /, "");
            return model === "scoped" ? i18n("Weekly · scoped") : i18n("Weekly · %1", model);
        }
        default: return limit.label;
        }
    }
    function errorText(answer) {
        const code = answer.error_code || "";
        switch (code) {
        case "no_login": return i18n("No Claude Code login in %1; run `claude` and /login", answer.error_arg);
        case "expired": return i18n("Token expired; open Claude Code to renew it");
        case "renew_failed": return i18n("Token renewal failed; open Claude Code to renew it");
        case "rejected": return i18n("Token rejected; open Claude Code to renew it");
        case "network": return i18n("Network error: %1", answer.error_arg);
        case "bad_response": return i18n("Unexpected answer from the server");
        case "http_429": return i18n("Rate limited; waiting before asking again");
        }
        if (code.startsWith("http_") && answer.error_arg)
            return i18n("HTTP %1 from %2", code.slice(5), answer.error_arg);
        return answer.error;
    }
    function localized(answer) {
        if (answer.limits)
            answer.limits = answer.limits.map(l => Object.assign({}, l, { label: limitLabel(l) }));
        if (answer.error)
            answer.error = errorText(answer);
        return answer;
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

    // Whether any Claude Code instance is running, polled with watch_activity.py --list;
    // while none is (and the option is on) the widget takes no room in the panel.
    property bool claudeRunning: false
    readonly property bool editMode: Plasmoid.containment && Plasmoid.containment.corona
        ? Plasmoid.containment.corona.editMode : false
    readonly property bool hidden: Plasmoid.configuration.hideWhenNotRunning && !claudeRunning && !expanded && !editMode
    function checkRunning() {
        let cmd = "/usr/bin/python3 -I " + _quote(_watchScript) + " --list";
        if (Plasmoid.configuration.configDir)
            cmd += " --config-dir " + _quote(Plasmoid.configuration.configDir);
        runningRunner.connectSource(cmd);
    }

    P5Support.DataSource {
        id: runningRunner
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => {
            disconnectSource(sourceName);
            if (!data.stdout)
                return;  // killed, e.g. while the shell quits; the next check answers
            try {
                const answer = JSON.parse(data.stdout);
                if (answer.ok)
                    root.claudeRunning = answer.sessions.length > 0;
            } catch (e) {
                console.warn("claudeusage: session check failed:", data.stderr || e);
            }
        }
    }
    Timer {
        interval: 5000
        running: Plasmoid.configuration.hideWhenNotRunning
        repeat: true
        triggeredOnStart: true
        onTriggered: root.checkRunning()
    }

    onExpandedChanged: () => {
        if (root.expanded) {
            tokenOffset = 0;
            loadTokens();
        } else {
            // After Plasma has put back the status it had before the popup opened.
            Qt.callLater(root.applyStatus);
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
                root.usage = root.localized(JSON.parse(data.stdout));
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
        applyStatus();
        refresh(false);
        loadTokens();
        if (liveUpdates)
            watch();
    }

    // The widget's own icon, shipped in the package (also used by the settings window).
    Plasmoid.icon: Qt.resolvedUrl("../icons/claude-usage.svg").toString().replace(/^file:\/\//, "")
    // Set by hand rather than bound: Plasma assigns Plasmoid.status itself while the
    // popup is open, which would break a binding and leave the widget shown when
    // Claude Code quits after the popup was used once.
    readonly property int wantedStatus: hidden ? PlasmaCore.Types.HiddenStatus
        : hasData && Math.max(percentOf(panelLimit), percentOf(weeklyLimit)) >= Plasmoid.configuration.criticalPercent
        ? PlasmaCore.Types.NeedsAttentionStatus : PlasmaCore.Types.ActiveStatus
    function applyStatus() {
        if (!expanded)
            Plasmoid.status = wantedStatus;
    }
    onWantedStatusChanged: applyStatus()

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
