.pragma library

// "now", "42m", "2h 13m", "3d 4h"
function duration(seconds) {
    if (seconds < 60)
        return "now";
    const m = Math.floor(seconds / 60);
    if (m < 60)
        return m + "m";
    const h = Math.floor(m / 60);
    if (h < 24)
        return h + "h " + (m % 60) + "m";
    return Math.floor(h / 24) + "d " + (h % 24) + "h";
}

function secondsUntil(isoString, nowMs) {
    if (!isoString)
        return NaN;
    return (Date.parse(isoString) - nowMs) / 1000;
}

// The limit the panel shows: 0 session, 1 weekly (all models), 2 most used.
// Falls back to the first limit when the plan has no such window.
function pickLimit(limits, mode) {
    if (!limits || limits.length === 0)
        return null;
    if (mode === 2)
        return limits.reduce((a, b) => (b.percent > a.percent ? b : a));
    const kind = mode === 1 ? "weekly_all" : "session";
    return limits.find(l => l.kind === kind) || limits[0];
}

// 950, 12.4K, 3.1M, 2.07B
function compact(n) {
    const units = [[1e9, "B"], [1e6, "M"], [1e3, "K"]];
    for (const [size, suffix] of units) {
        if (n >= size * 0.9995) { // 999999 is "1M", not "1000K"
            const v = n / size;
            return parseFloat(v.toFixed(v >= 100 ? 0 : v >= 10 ? 1 : 2)) + suffix;
        }
    }
    return String(Math.round(n));
}

// $0.42, $8.21, $463, $1,270: US dollars whatever the locale, as Claude Code shows them.
function money(usd) {
    if (usd > 0 && usd < 0.005)
        return "<$0.01";
    return "$" + Number(usd).toLocaleString(Qt.locale("en_US"), "f", usd >= 100 ? 0 : 2);
}

// The panel text: percent used and/or the reset time, in one of three styles
// (0 time left, 1 clock time, 2 both).
function panelText(percent, resetsAt, nowMs, showPercent, showReset, style) {
    let parts = [];
    if (showPercent)
        parts.push(Math.round(percent) + "%");
    const s = secondsUntil(resetsAt, nowMs);
    if (showReset && s > 0) {
        const clock = Qt.locale().toString(new Date(resetsAt), s < 86400 ? "HH:mm" : "ddd HH:mm");
        parts.push(style === 1 ? clock : style === 2 ? duration(s) + " · " + clock : duration(s));
    }
    return parts.join(" · ");
}

// Percent change, or NaN when there is nothing to compare with.
function change(total, previous) {
    return previous > 0 ? (total - previous) / previous * 100 : NaN;
}

// Whether bucket i gets an axis label.
function isTick(period, i) {
    switch (period) {
    case "session": return i % 4 === 0;
    case "day": return i % 6 === 0;
    case "month": return i % 7 === 0;
    default: return true;
    }
}
