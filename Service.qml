import QtQuick
import Quickshell
import Quickshell.Io

// One service instance owns all backend I/O. Omarchy creates a bar widget per
// monitor, so putting these processes in Panel.qml would duplicate polling and
// could race short commands against the same user supervisor.
Item {
    id: root

    property var shell: null
    property var manifest: null
    readonly property string moduleName: "omaphone.phone"
    readonly property string helperPath: manifest && manifest.__sourceDir ? String(manifest.__sourceDir) + "/scripts/omaphone.py" : ""
    property var phoneStatus: ({
        "schemaVersion": 1,
        "backendVersion": "",
        "phase": "unconfigured",
        "configured": false,
        "backendInstalled": false,
        "dependenciesReady": false,
        "missingDependencies": [],
        "online": false,
        "busy": false,
        "onion": "",
        "remoteAddress": "",
        "localTalking": false,
        "remoteTalking": false,
        "messages": [],
        "settings": ({
        }),
        "lastError": ""
    })
    property bool statusLoaded: false
    property string statusReadError: ""
    property string actionError: ""
    property string notice: ""
    property int pttDesired: 0
    property int pttApplied: 0
    property int stateGeneration: 0
    readonly property string phase: String(phoneStatus.phase || "unconfigured")
    readonly property bool configured: phoneStatus.configured === true
    readonly property bool backendInstalled: phoneStatus.backendInstalled === true
    readonly property bool dependenciesReady: phoneStatus.dependenciesReady === true
    readonly property bool ready: configured && backendInstalled && dependenciesReady
    readonly property bool onlineState: phoneStatus.online === true
    readonly property bool connected: phase === "connected"
    readonly property bool actionBusy: actionProcess.running || actionProcess.exitSeen || actionProcess.startPending || inviteProcess.running || inviteProcess.startPending
    readonly property bool commandBusy: actionBusy || clipboardBusy || phoneStatus.busy === true
    readonly property bool clipboardBusy: clipboardProcess.running || clipboardProcess.startPending
    readonly property bool fastPolling: phoneStatus.busy === true || phase === "starting" || phase === "calling" || phase === "connected" || phase === "testing" || phase === "relay" || pttProcess.running || pttProcess.exitSeen
    readonly property int pollInterval: fastPolling ? 500 : (onlineState ? 1500 : 10000)

    function applyStatus(raw) {
        var parsed;
        try {
            parsed = JSON.parse(String(raw || ""));
        } catch (error) {
            statusReadError = "Omaphone returned an unreadable status";
            return false;
        }
        if (!parsed || typeof parsed !== "object") {
            statusReadError = "Omaphone returned an empty status";
            return false;
        }
        var messages = Array.isArray(parsed.messages) ? parsed.messages : [];
        var safeMessages = [];
        for (var i = Math.max(0, messages.length - 20); i < messages.length; i++) {
            var message = messages[i];
            if (!message || typeof message !== "object")
                continue;

            safeMessages.push({
                "direction": String(message.direction || "incoming") === "outgoing" ? "outgoing" : "incoming",
                "text": String(message.text || "").substring(0, 2000),
                "timestamp": String(message.timestamp || "")
            });
        }
        var rawSettings = parsed.settings && typeof parsed.settings === "object" ? parsed.settings : ({
        });
        var safeSettings = {
            "quality": ["low", "balanced", "high"].indexOf(String(rawSettings.quality || "")) >= 0 ? String(rawSettings.quality) : "balanced",
            "voiceEffect": ["none", "deep", "high", "robot", "echo", "whisper"].indexOf(String(rawSettings.voiceEffect || "")) >= 0 ? String(rawSettings.voiceEffect) : "none",
            "chime": ["off", "tone", "double", "chirp", "ding", "click"].indexOf(String(rawSettings.chime || "")) >= 0 ? String(rawSettings.chime) : "tone",
            "snowflake": rawSettings.snowflake === true,
            "hmac": rawSettings.hmac !== false
        };
        phoneStatus = {
            "schemaVersion": Number(parsed.schemaVersion || 1),
            "backendVersion": String(parsed.backendVersion || ""),
            "phase": String(parsed.phase || "error"),
            "configured": parsed.configured === true,
            "backendInstalled": parsed.backendInstalled === true,
            "dependenciesReady": parsed.dependenciesReady === true,
            "missingDependencies": Array.isArray(parsed.missingDependencies) ? parsed.missingDependencies.map(function(item) {
                return String(item);
            }) : [],
            "online": parsed.online === true,
            "busy": parsed.busy === true,
            "onion": String(parsed.onion || ""),
            "remoteAddress": String(parsed.remoteAddress || ""),
            "localTalking": parsed.localTalking === true,
            "remoteTalking": parsed.remoteTalking === true,
            "messages": safeMessages,
            "settings": safeSettings,
            "lastError": String(parsed.lastError || "")
        };
        statusLoaded = true;
        statusReadError = "";
        if (!pttProcess.running) {
            pttApplied = phoneStatus.localTalking ? 1 : 0;
            if (pttDesired !== pttApplied)
                pttRetry.restart();

        }
        return true;
    }

    function refresh() {
        if (statusProcess.running || statusProcess.exitSeen || statusProcess.startPending || actionBusy || pttProcess.running || pttProcess.exitSeen || helperPath === "")
            return ;

        statusProcess.output = "";
        statusProcess.outputReady = false;
        statusProcess.exitSeen = false;
        statusProcess.startPending = true;
        statusProcess.generation = stateGeneration;
        statusProcess.command = ["python3", helperPath, "status"];
        statusProcess.running = true;
        statusWatchdog.restart();
    }

    function successNotice(kind) {
        if (kind === "setup")
            return "Setup complete";

        if (kind === "install-deps")
            return "Requirements installed";

        if (kind === "online")
            return "Going online…";

        if (kind === "offline")
            return "Omaphone is offline";

        if (kind === "call")
            return "Calling…";

        if (kind === "pair")
            return "Invite paired";

        if (kind === "audio-test")
            return "Audio test started";

        if (kind === "hangup")
            return "Ending call…";

        if (kind === "relay")
            return "Relay started";

        if (kind === "rotate")
            return "Rotating onion identity…";

        if (kind === "clear-chat")
            return "Local chat history cleared";

        return "";
    }

    function failureLabel(kind) {
        if (kind === "install-deps")
            return "Could not install requirements";

        if (kind === "audio-test")
            return "Audio test failed";

        if (kind === "copy-invite")
            return "Could not create an invite";

        if (kind === "config")
            return "Could not save that setting";

        if (kind === "send")
            return "Message was not sent";

        if (kind === "pair")
            return "Could not pair that invite";

        if (kind === "call")
            return "Could not place the call";

        if (kind === "rotate")
            return "Identity rotation failed";

        if (kind === "clear-chat")
            return "Could not clear local chat history";

        return "Omaphone could not complete " + String(kind || "that action");
    }

    function runAction(arguments, stdinText, kind) {
        if (actionProcess.running || actionProcess.exitSeen || actionProcess.startPending || helperPath === "")
            return false;

        actionError = "";
        notice = "";
        actionProcess.kind = String(kind || "action");
        actionProcess.input = String(stdinText || "");
        actionProcess.output = "";
        actionProcess.outputReady = false;
        actionProcess.exitSeen = false;
        actionProcess.startedOk = false;
        actionProcess.startPending = true;
        actionProcess.timedOut = false;
        stateGeneration++;
        actionProcess.command = ["python3", helperPath].concat(arguments);
        actionProcess.running = true;
        actionStartTimeout.restart();
        actionWatchdog.interval = kind === "install-deps" ? 600000 : (kind === "setup" ? 60000 : 30000);
        actionWatchdog.restart();
        return true;
    }

    function setup() {
        if (commandBusy)
            return false;

        return runAction(["setup"], "", "setup");
    }

    function installDependencies() {
        if (commandBusy)
            return false;

        return runAction(["install-deps"], "", "install-deps");
    }

    function goOnline() {
        if (!ready || onlineState || commandBusy)
            return false;

        return runAction(["online"], "", "online");
    }

    function goOffline() {
        if (!ready || !onlineState || commandBusy)
            return false;

        requestPtt(false);
        return runAction(["offline"], "", "offline");
    }

    function toggleOnline() {
        return onlineState ? goOffline() : goOnline();
    }

    function addressIsSafe(value) {
        // TerminalPhone uses a v3 onion identity and a fixed configured port.
        // Invite codes can contain the room secret and only travel over stdin.
        return /^[a-z2-7]{56}\.onion$/i.test(String(value || ""));
    }

    function callAddress(value) {
        if (commandBusy)
            return false;

        if (!onlineState || phase !== "listening") {
            actionError = "Go online before placing a call";
            return false;
        }
        var address = String(value || "").trim();
        if (!addressIsSafe(address)) {
            actionError = "Enter a full 56-character .onion address; paste invite codes into Pair instead";
            return false;
        }
        return runAction(["call", address], "", "call");
    }

    function pairInvite(value) {
        if (commandBusy)
            return false;

        var invite = String(value || "").trim();
        if (invite === "") {
            actionError = "Paste an Omaphone invite first";
            return false;
        }
        // The opaque invite (and its embedded room secret) never enters argv.
        return runAction(["pair"], invite, "pair");
    }

    function copyInvite() {
        if (commandBusy)
            return false;

        if (String(phoneStatus.onion || "") === "")
            return false;

        actionError = "";
        notice = "";
        inviteProcess.output = "";
        inviteProcess.startedOk = false;
        inviteProcess.startPending = true;
        inviteProcess.command = ["python3", helperPath, "invite"];
        inviteProcess.running = true;
        inviteStartTimeout.restart();
        return true;
    }

    function sendMessage(value) {
        if (commandBusy)
            return false;

        var message = String(value || "").trim();
        if (message === "")
            return false;

        return runAction(["send"], message, "send");
    }

    function hangup() {
        requestPtt(false);
        return runAction(["hangup"], "", "hangup");
    }

    function setConfig(key, value) {
        if (commandBusy)
            return false;

        return runAction(["config", String(key), String(value)], "", "config");
    }

    function toggleConfig(key, current) {
        return setConfig(key, current ? "false" : "true");
    }

    function runAudioTest() {
        if (commandBusy)
            return false;

        return runAction(["audio-test"], "", "audio-test");
    }

    function startRelay() {
        if (commandBusy)
            return false;

        return runAction(["relay"], "", "relay");
    }

    function rotateIdentity() {
        if (commandBusy)
            return false;

        if (onlineState || phase === "calling" || phase === "connected" || phase === "relay")
            return false;

        return runAction(["rotate", "--confirm"], "", "rotate");
    }

    function clearChat() {
        if (commandBusy)
            return false;

        return runAction(["clear-chat"], "", "clear-chat");
    }

    function copyOpaqueInvite(invite) {
        var value = String(invite || "").trim();
        if (value.indexOf("omaphone:v1:") !== 0 || clipboardProcess.running) {
            actionError = "Omaphone did not produce a valid invite";
            return ;
        }
        // The fragment is fixed; the opaque invite is written only on stdin.
        // read exits after one newline and therefore closes wl-copy's input.
        clipboardProcess.payload = value;
        clipboardProcess.startedOk = false;
        clipboardProcess.startPending = true;
        clipboardProcess.command = ["bash", "-c", "IFS= read -r line; printf %s \"$line\" | wl-copy"];
        clipboardProcess.running = true;
        clipboardStartTimeout.restart();
    }

    function requestPtt(start) {
        if (start && !connected)
            return false;

        pttDesired = start ? 1 : 0;
        drivePtt();
        return true;
    }

    function drivePtt() {
        if (pttProcess.running || pttProcess.exitSeen || pttProcess.startPending || helperPath === "")
            return ;

        if (pttDesired === pttApplied)
            return ;

        if (pttDesired === 1 && !connected) {
            pttDesired = 0;
            return ;
        }
        pttProcess.requested = pttDesired;
        pttProcess.output = "";
        pttProcess.outputReady = false;
        pttProcess.exitSeen = false;
        pttProcess.startedOk = false;
        pttProcess.startPending = true;
        stateGeneration++;
        pttProcess.command = ["python3", helperPath, "ptt", pttDesired === 1 ? "start" : "stop"];
        pttProcess.running = true;
        pttStartTimeout.restart();
        pttWatchdog.restart();
    }

    function finishStatusProcess() {
        if (!statusProcess.exitSeen || !statusProcess.outputReady)
            return ;

        statusWatchdog.stop();
        if (statusProcess.generation === stateGeneration) {
            if (statusProcess.exitCodeValue === 0)
                applyStatus(statusProcess.output);
            else
                statusReadError = "Could not read Omaphone status";
        }
        statusProcess.output = "";
        statusProcess.exitSeen = false;
        statusProcess.outputReady = false;
    }

    function finishActionProcess() {
        if (!actionProcess.exitSeen || !actionProcess.outputReady)
            return ;

        actionWatchdog.stop();
        var exitCode = actionProcess.exitCodeValue;
        var finishedKind = actionProcess.kind;
        var finishedOutput = actionProcess.output;
        actionProcess.kind = "";
        actionProcess.input = "";
        actionProcess.output = "";
        actionProcess.exitSeen = false;
        actionProcess.outputReady = false;
        actionProcess.startPending = false;
        if (exitCode === 0) {
            actionError = "";
            applyStatus(finishedOutput);
            notice = successNotice(finishedKind);
        } else if (!actionProcess.timedOut) {
            actionError = failureLabel(finishedKind);
        }
        refresh();
        settleRefresh.restart();
    }

    function finishPttProcess() {
        if (!pttProcess.exitSeen || !pttProcess.outputReady)
            return ;

        pttWatchdog.stop();
        var exitCode = pttProcess.exitCodeValue;
        if (exitCode === 0) {
            pttApplied = pttProcess.requested;
            applyStatus(pttProcess.output);
        } else {
            if (pttProcess.requested === 1)
                pttDesired = 0;

            actionError = pttProcess.requested === 1 ? "Could not start recording" : "Could not stop recording; retrying";
        }
        pttProcess.output = "";
        pttProcess.exitSeen = false;
        pttProcess.outputReady = false;
        if (pttDesired !== pttApplied)
            pttRetry.restart();

        refresh();
    }

    onManifestChanged: refresh()
    onConnectedChanged: {
        if (!connected)
            requestPtt(false);

    }
    Component.onCompleted: refresh()
    Component.onDestruction: requestPtt(false)

    Timer {
        interval: root.pollInterval
        running: true
        repeat: true
        onTriggered: root.refresh()
    }

    Timer {
        id: settleRefresh

        interval: 250
        repeat: false
        onTriggered: root.refresh()
    }

    Timer {
        id: pttRetry

        interval: 500
        repeat: false
        onTriggered: root.drivePtt()
    }

    // A held PTT is a renewable backend lease. If the shell disappears, the
    // daemon's short watchdog releases the microphone instead of recording on.
    Timer {
        interval: 3000
        running: root.connected && root.pttDesired === 1 && root.pttApplied === 1
        repeat: true
        onTriggered: {
            if (!pttProcess.running && !pttProcess.exitSeen) {
                root.pttApplied = 0;
                root.drivePtt();
            }
        }
    }

    Timer {
        id: statusWatchdog

        interval: 10000
        repeat: false
        onTriggered: {
            root.statusReadError = "Omaphone status check timed out";
            if (statusProcess.running) {
                statusProcess.signal(9);
            } else {
                statusProcess.output = "";
                statusProcess.outputReady = false;
                statusProcess.exitSeen = false;
                statusProcess.startPending = false;
            }
        }
    }

    Timer {
        id: actionWatchdog

        repeat: false
        onTriggered: {
            actionProcess.input = "";
            actionProcess.timedOut = true;
            root.notice = "";
            root.actionError = root.failureLabel(actionProcess.kind) + " (timed out)";
            if (actionProcess.running)
                actionProcess.signal(9);

        }
    }

    Timer {
        id: pttStartTimeout

        interval: 1500
        repeat: false
        onTriggered: {
            if (pttProcess.startedOk || pttProcess.running)
                return ;

            if (pttProcess.requested === 1)
                root.pttDesired = 0;

            pttProcess.output = "";
            pttProcess.outputReady = false;
            pttProcess.exitSeen = false;
            pttProcess.startPending = false;
            pttWatchdog.stop();
            root.actionError = "Could not control push-to-talk";
        }
    }

    Timer {
        id: pttWatchdog

        interval: 10000
        repeat: false
        onTriggered: {
            if (pttProcess.requested === 1)
                root.pttDesired = 0;

            root.actionError = "Push-to-talk control timed out";
            if (pttProcess.running)
                pttProcess.signal(9);

        }
    }

    Timer {
        id: actionStartTimeout

        interval: 1500
        repeat: false
        onTriggered: {
            if (actionProcess.startedOk || actionProcess.running || actionProcess.kind === "")
                return ;

            var failedKind = actionProcess.kind;
            // A failed process never reaches onStarted/onExited. Scrub stdin here so
            // an invite or message cannot remain in the long-lived shell object.
            actionProcess.input = "";
            actionProcess.output = "";
            actionProcess.outputReady = false;
            actionProcess.exitSeen = false;
            actionProcess.startPending = false;
            actionProcess.kind = "";
            actionWatchdog.stop();
            root.notice = "";
            root.actionError = root.failureLabel(failedKind);
        }
    }

    Timer {
        id: inviteStartTimeout

        interval: 1500
        repeat: false
        onTriggered: {
            if (inviteProcess.startedOk || inviteProcess.running)
                return ;

            inviteProcess.output = "";
            inviteProcess.startPending = false;
            root.notice = "";
            root.actionError = "Could not create an invite";
        }
    }

    Timer {
        id: clipboardStartTimeout

        interval: 1500
        repeat: false
        onTriggered: {
            if (clipboardProcess.startedOk || clipboardProcess.running)
                return ;

            clipboardProcess.payload = "";
            clipboardProcess.startPending = false;
            root.notice = "";
            root.actionError = "Could not copy the invite";
        }
    }

    Timer {
        id: inviteWatchdog

        interval: 30000
        repeat: false
        onTriggered: {
            inviteProcess.output = "";
            root.actionError = "Could not create an invite (timed out)";
            if (inviteProcess.running)
                inviteProcess.signal(9);

        }
    }

    Timer {
        id: clipboardWatchdog

        interval: 30000
        repeat: false
        onTriggered: {
            clipboardProcess.payload = "";
            root.actionError = "Could not copy the invite (timed out)";
            if (clipboardProcess.running)
                clipboardProcess.signal(9);

        }
    }

    Process {
        id: statusProcess

        property string output: ""
        property bool outputReady: false
        property bool exitSeen: false
        property int exitCodeValue: -1
        property int generation: 0
        property bool startPending: false

        onExited: function(exitCode) {
            startPending = false;
            exitCodeValue = exitCode;
            exitSeen = true;
            root.finishStatusProcess();
        }
        onStarted: startPending = false

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                statusProcess.output = String(text || "");
                statusProcess.outputReady = true;
                root.finishStatusProcess();
            }
        }

    }

    Process {
        id: actionProcess

        property string kind: ""
        property string input: ""
        property string output: ""
        property bool outputReady: false
        property bool exitSeen: false
        property bool startedOk: false
        property bool startPending: false
        property bool timedOut: false
        property int exitCodeValue: -1

        stdinEnabled: true
        onStarted: {
            startedOk = true;
            startPending = false;
            actionStartTimeout.stop();
            if (input !== "")
                write(input + "\n");

            // Pair invites and message text are scrubbed immediately after write.
            input = "";
        }
        onExited: function(exitCode) {
            startPending = false;
            exitCodeValue = exitCode;
            exitSeen = true;
            root.finishActionProcess();
        }

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                actionProcess.output = String(text || "");
                actionProcess.outputReady = true;
                root.finishActionProcess();
            }
        }

    }

    // Invites contain the room secret. SplitParser emits a line without
    // retaining it in a read-only collector after we scrub `output`.
    Process {
        id: inviteProcess

        property string output: ""
        property bool startedOk: false
        property bool startPending: false

        onStarted: {
            startedOk = true;
            startPending = false;
            inviteStartTimeout.stop();
            inviteWatchdog.restart();
        }
        onExited: function(exitCode) {
            startPending = false;
            inviteWatchdog.stop();
            var invite = output;
            output = "";
            if (exitCode === 0) {
                root.copyOpaqueInvite(invite);
            } else {
                root.notice = "";
                root.actionError = "Could not create an invite";
            }
            root.refresh();
        }

        stdout: SplitParser {
            onRead: function(line) {
                inviteProcess.output = String(line || "");
            }
        }

    }

    Process {
        id: clipboardProcess

        property string payload: ""
        property bool startedOk: false
        property bool startPending: false

        stdinEnabled: true
        onStarted: {
            startedOk = true;
            startPending = false;
            clipboardStartTimeout.stop();
            clipboardWatchdog.restart();
            write(payload + "\n");
            payload = "";
        }
        onExited: function(exitCode) {
            startPending = false;
            clipboardWatchdog.stop();
            // This is the sole temporary property that contains our own opaque
            // invite. Clear it as soon as the stdin-to-wl-copy bridge exits.
            payload = "";
            if (exitCode === 0) {
                root.notice = "Invite copied";
            } else {
                root.notice = "";
                root.actionError = "Could not copy the invite";
            }
        }
    }

    Process {
        id: pttProcess

        property int requested: 0
        property string output: ""
        property bool outputReady: false
        property bool exitSeen: false
        property bool startedOk: false
        property bool startPending: false
        property int exitCodeValue: -1

        onExited: function(exitCode) {
            startPending = false;
            exitCodeValue = exitCode;
            exitSeen = true;
            root.finishPttProcess();
        }
        onStarted: {
            startedOk = true;
            startPending = false;
            pttStartTimeout.stop();
        }

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                pttProcess.output = String(text || "");
                pttProcess.outputReady = true;
                root.finishPttProcess();
            }
        }

    }

    IpcHandler {
        function open() : string {
            if (root.shell)
                root.shell.summon(root.moduleName, "{}");

            return "ok";
        }

        function close() : string {
            root.requestPtt(false);
            if (root.shell)
                root.shell.hide(root.moduleName);

            return "ok";
        }

        function show() : string {
            return open();
        }

        function hide() : string {
            return close();
        }

        function toggle() : string {
            if (root.shell)
                root.shell.toggle(root.moduleName, "{}");

            return "ok";
        }

        function status() : string {
            root.refresh();
            return JSON.stringify(root.phoneStatus);
        }

        function online() : string {
            return root.goOnline() ? "ok" : "busy";
        }

        function offline() : string {
            return root.goOffline() ? "ok" : "busy";
        }

        function hangup() : string {
            return root.hangup() ? "ok" : "busy";
        }

        target: root.moduleName
    }

}
