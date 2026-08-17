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
        "snowflakeAvailable": false,
        "online": false,
        "busy": false,
        "onion": "",
        "remoteAddress": "",
        "pairedAddress": "",
        "peerKind": "",
        "hasPeer": false,
        "preferredRole": "",
        "selfPeer": false,
        "callStage": "",
        "torProgress": 0,
        "lastCallOutcome": "",
        "lastCallMessage": "",
        "callOutcomeSequence": 0,
        "groupCall": false,
        "roomSize": 0,
        "relayReady": false,
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
    property string cueText: ""
    property bool inviteAndWaitPending: false
    property int joinSuccessSequence: 0
    property int pttDesired: 0
    property int pttApplied: 0
    property int stateGeneration: 0
    property bool endingCall: false
    property var cueQueue: []
    readonly property string phase: String(phoneStatus.phase || "unconfigured")
    readonly property bool configured: phoneStatus.configured === true
    readonly property bool backendInstalled: phoneStatus.backendInstalled === true
    readonly property bool dependenciesReady: phoneStatus.dependenciesReady === true
    readonly property var missingDependencies: Array.isArray(phoneStatus.missingDependencies) ? phoneStatus.missingDependencies : []
    readonly property bool onlyOptionalSnowflakeMissing: missingDependencies.length === 1 && String(missingDependencies[0]) === "snowflake-client"
    readonly property bool snowflakeAvailable: phoneStatus.snowflakeAvailable === true
    readonly property bool snowflakeEnabled: phoneStatus.settings && typeof phoneStatus.settings === "object" && phoneStatus.settings.snowflake === true
    readonly property bool snowflakeBlocked: snowflakeEnabled && !snowflakeAvailable
    // Older backends counted Snowflake as a required dependency. Keep the
    // phone usable long enough to switch that optional transport back off.
    readonly property bool ready: configured && backendInstalled && (dependenciesReady || onlyOptionalSnowflakeMissing)
    readonly property bool onlineState: phoneStatus.online === true
    readonly property bool connected: phase === "connected"
    readonly property bool actionBusy: actionProcess.running || actionProcess.exitSeen || actionProcess.startPending || inviteProcess.running || inviteProcess.startPending
    readonly property bool commandBusy: actionBusy || clipboardBusy || phoneStatus.busy === true
    readonly property bool clipboardBusy: clipboardProcess.running || clipboardProcess.startPending
    readonly property bool fastPolling: phoneStatus.busy === true || phase === "starting" || phase === "calling" || phase === "connected" || phase === "testing" || phase === "relay" || pttProcess.running || pttProcess.exitSeen
    readonly property int pollInterval: fastPolling ? 500 : (onlineState ? 1500 : 10000)

    function safePlainText(value, limit) {
        var maximum = Math.max(1, Number(limit || 180));
        var text = String(value || "");
        // Strip terminal colour/control sequences and the CLI's fixed prefix.
        text = text.replace(/\x1b\][^\x07]*(?:\x07|\x1b\\)/g, "");
        text = text.replace(/\x1b\[[0-?]*[ -\/]*[@-~]/g, "");
        text = text.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f]/g, "");
        text = text.replace(/[\r\n\t]+/g, " ").replace(/\s+/g, " ").trim();
        text = text.replace(/^omaphone\s*:\s*/i, "").replace(/^error\s*:\s*/i, "").trim();
        if (text.length > maximum)
            text = text.substring(0, maximum - 1).trim() + "…";

        return text;
    }

    function actionFailureMessage(kind, stderrText) {
        // Dependency/setup tools can emit package-manager output. Never place
        // that raw output in the panel; only the small phone-action surface is
        // defined to return friendly, bounded errors.
        var maySurfaceDetail = ["call", "call-peer", "join", "clear-peer"].indexOf(String(kind || "")) >= 0;
        var rawError = String(stderrText || "").replace(/\x1b\[[0-?]*[ -\/]*[@-~]/g, "").replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f]/g, "").trim();
        var knownBackendError = /^omaphone\s*:/i.test(rawError);
        var detail = maySurfaceDetail && knownBackendError ? safePlainText(rawError, 180) : "";
        if (["join", "call-peer"].indexOf(String(kind || "")) >= 0)
            detail = detail.replace(/Omaphone invite/gi, "private card").replace(/\binvite\b/gi, "card");

        if (detail !== "")
            detail = detail.charAt(0).toUpperCase() + detail.substring(1);

        return detail !== "" ? detail : failureLabel(kind);
    }

    function cueCommand(kind) {
        if (kind === "outgoing")
            return ["play", "-q", "-n", "synth", "0.10", "sine", "420", "vol", "0.18"];

        if (kind === "connected")
            return ["play", "-q", "-n", "synth", "0.18", "sine", "440-660", "vol", "0.22"];

        if (kind === "failure")
            return ["play", "-q", "-n", "synth", "0.16", "sine", "190", "vol", "0.20"];

        return ["play", "-q", "-n", "synth", "0.10", "sine", "300-230", "vol", "0.18"];
    }

    function queueCue(kind, visibleText) {
        cueText = safePlainText(visibleText, 80);
        cueTextTimer.restart();
        if (String(phoneStatus.settings && phoneStatus.settings.chime || "tone") === "off")
            return ;

        var nextQueue = cueQueue.slice(0);
        if (nextQueue.length < 3)
            nextQueue.push(String(kind || "end"));

        cueQueue = nextQueue;
        driveCue();
    }

    function driveCue() {
        if (cueProcess.running || cueProcess.startPending || cueQueue.length === 0)
            return ;

        var nextQueue = cueQueue.slice(0);
        var kind = String(nextQueue.shift() || "end");
        cueQueue = nextQueue;
        cueProcess.startPending = true;
        cueProcess.command = cueCommand(kind);
        cueProcess.running = true;
        cueStartTimeout.restart();
    }

    function handleCallTransition(previousPhase, previousOutcomeSequence) {
        var currentPhase = String(phoneStatus.phase || "");
        var currentOutcomeSequence = Number(phoneStatus.callOutcomeSequence || 0);
        if (currentOutcomeSequence > previousOutcomeSequence && ["failed", "timeout"].indexOf(String(phoneStatus.lastCallOutcome || "")) >= 0) {
            queueCue("failure", String(phoneStatus.lastCallMessage || "Call failed"));
            endingCall = false;
            return ;
        }
        if (currentPhase === "connected" && previousPhase !== "connected") {
            queueCue("connected", previousPhase === "listening" ? "Incoming call connected" : "Call connected");
            endingCall = false;
        } else if (previousPhase === "connected" && currentPhase !== "connected") {
            queueCue("end", "Call ended");
            endingCall = false;
        } else if (endingCall && previousPhase === "calling" && currentPhase !== "calling") {
            queueCue("end", "Call ended");
            endingCall = false;
        }
    }

    function applyStatus(raw) {
        var hadStatus = statusLoaded;
        var previousPhase = phase;
        var previousOutcomeSequence = Number(phoneStatus.callOutcomeSequence || 0);
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
        var safeRoomSize = typeof parsed.roomSize === "number" && isFinite(parsed.roomSize) ? Math.max(0, Math.min(10000, Math.floor(parsed.roomSize))) : 0;
        var pairedAddress = addressIsSafe(parsed.pairedAddress) ? String(parsed.pairedAddress).toLowerCase() : "";
        var peerKind = pairedAddress === "" ? "" : (String(parsed.peerKind || "") === "group" ? "group" : "direct");
        var preferredRole = ["caller", "listener"].indexOf(String(parsed.preferredRole || "")) >= 0 ? String(parsed.preferredRole) : "";
        var callStage = ["preparing", "opening-tor", "dialing"].indexOf(String(parsed.callStage || "")) >= 0 ? String(parsed.callStage) : "";
        var torProgress = typeof parsed.torProgress === "number" && isFinite(parsed.torProgress) ? Math.max(0, Math.min(100, Math.floor(parsed.torProgress))) : 0;
        var lastCallOutcome = ["failed", "timeout"].indexOf(String(parsed.lastCallOutcome || "")) >= 0 ? String(parsed.lastCallOutcome) : "";
        var callOutcomeSequence = typeof parsed.callOutcomeSequence === "number" && isFinite(parsed.callOutcomeSequence) ? Math.max(0, Math.floor(parsed.callOutcomeSequence)) : 0;
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
            "snowflakeAvailable": parsed.snowflakeAvailable === true,
            "online": parsed.online === true,
            "busy": parsed.busy === true,
            "onion": String(parsed.onion || ""),
            "remoteAddress": String(parsed.remoteAddress || ""),
            "pairedAddress": pairedAddress,
            "peerKind": peerKind,
            "hasPeer": parsed.hasPeer === true && pairedAddress !== "",
            "preferredRole": preferredRole,
            "selfPeer": parsed.selfPeer === true,
            "callStage": callStage,
            "torProgress": torProgress,
            "lastCallOutcome": lastCallOutcome,
            "lastCallMessage": safePlainText(parsed.lastCallMessage, 220),
            "callOutcomeSequence": callOutcomeSequence,
            "groupCall": parsed.groupCall === true,
            "roomSize": safeRoomSize,
            "relayReady": parsed.relayReady === true && String(parsed.phase || "") === "relay",
            "localTalking": parsed.localTalking === true,
            "remoteTalking": parsed.remoteTalking === true,
            "messages": safeMessages,
            "settings": safeSettings,
            "lastError": safePlainText(parsed.lastError, 220)
        };
        if (notice === "Starting group host…" && (phoneStatus.relayReady === true || String(phoneStatus.phase || "") !== "relay"))
            notice = "";

        statusLoaded = true;
        statusReadError = "";
        if (hadStatus)
            handleCallTransition(previousPhase, previousOutcomeSequence);

        if (inviteAndWaitPending) {
            if (phase === "listening")
                maybeCopyWaitingCard();
            else if (phase === "error")
                inviteAndWaitPending = false;
        }
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
            return "Missing tools installed";

        if (kind === "online")
            return "Waiting for calls…";

        if (kind === "offline")
            return "Omaphone is offline";

        if (kind === "call" || kind === "call-peer")
            return "Calling…";

        if (kind === "join")
            return String(phoneStatus.peerKind || "") === "group" ? "Room saved — connecting…" : "Phone added — connecting…";

        if (kind === "clear-peer")
            return "Saved call cleared";

        if (kind === "audio-test")
            return "Audio test started";

        if (kind === "hangup")
            return "Ending call…";

        if (kind === "relay")
            return phoneStatus.relayReady === true ? "" : "Starting group host…";

        if (kind === "rotate")
            return "Changing your calling address…";

        if (kind === "clear-chat")
            return "Local chat history cleared";

        return "";
    }

    function failureLabel(kind) {
        if (kind === "install-deps")
            return "Could not install the missing tools";

        if (kind === "audio-test")
            return "Audio test failed";

        if (kind === "copy-invite")
            return "Could not create the private card";

        if (kind === "config")
            return "Could not save that setting";

        if (kind === "send")
            return "Message was not sent";

        if (kind === "join")
            return "Could not use that card";

        if (kind === "call-peer")
            return "Could not call the paired phone";

        if (kind === "clear-peer")
            return "Could not clear the saved call";

        if (kind === "call")
            return "Could not place the call";

        if (kind === "rotate")
            return "Could not change your calling address";

        if (kind === "relay")
            return "Could not host the group";

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
        actionProcess.errorOutput = "";
        actionProcess.outputReady = false;
        actionProcess.errorReady = false;
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
        if (["call", "call-peer", "join"].indexOf(String(kind || "")) >= 0)
            queueCue("outgoing", "Calling");

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
        if (!ready || snowflakeBlocked || commandBusy || phase === "calling" || phase === "connected" || phase === "relay")
            return false;

        if (onlineState && String(phoneStatus.preferredRole || "") === "listener")
            return false;

        return runAction(["online"], "", "online");
    }

    function goOffline() {
        if (!onlineState || actionBusy || clipboardBusy)
            return false;

        inviteAndWaitPending = false;
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

        var address = String(value || "").trim();
        if (!addressIsSafe(address)) {
            actionError = "Paste a full 56-character .onion calling address";
            return false;
        }
        return runAction(["call", address], "", "call");
    }

    function join(value) {
        if (commandBusy)
            return false;

        var invite = String(value || "").trim();
        if (invite === "") {
            actionError = "Paste a private contact card or room invite first";
            return false;
        }
        // The opaque invite (and its embedded room secret) never enters argv.
        return runAction(["join"], invite, "join");
    }

    function pairInvite(value) {
        return join(value);
    }

    function callPeer() {
        if (commandBusy)
            return false;

        return runAction(["call-peer"], "", "call-peer");
    }

    function clearPeer() {
        if (commandBusy)
            return false;

        inviteAndWaitPending = false;
        return runAction(["clear-peer"], "", "clear-peer");
    }

    function inviteAndWait() {
        if (!ready || snowflakeBlocked || commandBusy)
            return false;

        actionError = "";
        notice = phase === "listening" ? "Preparing private contact card…" : "Opening a private line…";
        inviteAndWaitPending = true;
        if (phase === "listening") {
            maybeCopyWaitingCard();
            return true;
        }
        if (!goOnline()) {
            inviteAndWaitPending = false;
            return false;
        }
        return true;
    }

    function maybeCopyWaitingCard() {
        if (!inviteAndWaitPending || phase !== "listening" || String(phoneStatus.onion || "") === "")
            return ;

        if (copyInvite(true))
            inviteAndWaitPending = false;

    }

    function copyInvite(waitingCard) {
        // A relay is a long-lived TerminalPhone session and therefore reports
        // busy, but creating an invite only packages the room key that the
        // supervisor already made for this session. Keep it available to the
        // host while blocking overlapping helpers and every other busy phase.
        if (actionBusy || clipboardBusy || (phoneStatus.busy === true && phase !== "relay" && phase !== "listening"))
            return false;

        if (String(phoneStatus.onion || "") === "")
            return false;

        actionError = "";
        notice = "";
        inviteProcess.output = "";
        inviteProcess.waitingCard = waitingCard === true;
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
        endingCall = phase === "calling" || phase === "connected";
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

    function copyOpaqueInvite(invite, waitingCard) {
        var value = String(invite || "").trim();
        if (value.indexOf("omaphone:v1:") !== 0 || clipboardProcess.running) {
            actionError = waitingCard ? "Omaphone did not produce a valid private contact card" : "Omaphone did not produce a valid private card";
            return ;
        }
        // The fragment is fixed; the opaque invite is written only on stdin.
        // read exits after one newline and therefore closes wl-copy's input.
        clipboardProcess.payload = value;
        clipboardProcess.waitingCard = waitingCard === true;
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
        if (!actionProcess.exitSeen || !actionProcess.outputReady || !actionProcess.errorReady)
            return ;

        actionWatchdog.stop();
        var exitCode = actionProcess.exitCodeValue;
        var finishedKind = actionProcess.kind;
        var finishedOutput = actionProcess.output;
        var finishedError = actionProcess.errorOutput;
        var timedOut = actionProcess.timedOut;
        actionProcess.kind = "";
        actionProcess.input = "";
        actionProcess.output = "";
        actionProcess.errorOutput = "";
        actionProcess.exitSeen = false;
        actionProcess.outputReady = false;
        actionProcess.errorReady = false;
        actionProcess.startPending = false;
        if (exitCode === 0) {
            if (applyStatus(finishedOutput)) {
                actionError = "";
                notice = successNotice(finishedKind);
                if (finishedKind === "join")
                    joinSuccessSequence++;

            } else {
                actionError = failureLabel(finishedKind);
            }
        } else if (!timedOut) {
            actionError = actionFailureMessage(finishedKind, finishedError);
            if (["call", "call-peer", "join"].indexOf(finishedKind) >= 0)
                queueCue("failure", actionError);

        }
        if (finishedKind === "online" && exitCode !== 0)
            inviteAndWaitPending = false;

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
    Component.onDestruction: {
        requestPtt(false);
        cueQueue = [];
        if (cueProcess.running)
            cueProcess.signal(15);

    }

    Timer {
        interval: root.pollInterval
        running: true
        repeat: true
        onTriggered: root.refresh()
    }

    Timer {
        id: cueTextTimer

        interval: 2600
        repeat: false
        onTriggered: root.cueText = ""
    }

    Timer {
        id: cueStartTimeout

        interval: 1500
        repeat: false
        onTriggered: {
            if (cueProcess.running || !cueProcess.startPending)
                return ;

            cueProcess.startPending = false;
            root.driveCue();
        }
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
            if (["call", "call-peer", "join"].indexOf(actionProcess.kind) >= 0)
                root.queueCue("failure", root.actionError);

            if (actionProcess.kind === "online")
                root.inviteAndWaitPending = false;

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
            actionProcess.errorOutput = "";
            actionProcess.outputReady = false;
            actionProcess.errorReady = false;
            actionProcess.exitSeen = false;
            actionProcess.startPending = false;
            actionProcess.kind = "";
            actionWatchdog.stop();
            root.notice = "";
            root.actionError = root.failureLabel(failedKind);
            if (["call", "call-peer", "join"].indexOf(failedKind) >= 0)
                root.queueCue("failure", root.actionError);

            if (failedKind === "online")
                root.inviteAndWaitPending = false;

        }
    }

    Timer {
        id: inviteStartTimeout

        interval: 1500
        repeat: false
        onTriggered: {
            if (inviteProcess.startedOk || inviteProcess.running)
                return ;

            var waitingCardCopy = inviteProcess.waitingCard;
            inviteProcess.output = "";
            inviteProcess.waitingCard = false;
            inviteProcess.startPending = false;
            root.notice = "";
            root.actionError = waitingCardCopy ? "Could not create the private contact card" : "Could not create a private card";
        }
    }

    Timer {
        id: clipboardStartTimeout

        interval: 1500
        repeat: false
        onTriggered: {
            if (clipboardProcess.startedOk || clipboardProcess.running)
                return ;

            var waitingCardCopy = clipboardProcess.waitingCard;
            clipboardProcess.payload = "";
            clipboardProcess.waitingCard = false;
            clipboardProcess.startPending = false;
            root.notice = "";
            root.actionError = waitingCardCopy ? "Could not copy the private contact card" : "Could not copy the private card";
        }
    }

    Timer {
        id: inviteWatchdog

        interval: 30000
        repeat: false
        onTriggered: {
            var waitingCardCopy = inviteProcess.waitingCard;
            inviteProcess.output = "";
            inviteProcess.waitingCard = false;
            root.actionError = waitingCardCopy ? "Could not create the private contact card (timed out)" : "Could not create a private card (timed out)";
            if (inviteProcess.running)
                inviteProcess.signal(9);

        }
    }

    Timer {
        id: clipboardWatchdog

        interval: 30000
        repeat: false
        onTriggered: {
            var waitingCardCopy = clipboardProcess.waitingCard;
            clipboardProcess.payload = "";
            clipboardProcess.waitingCard = false;
            root.actionError = waitingCardCopy ? "Could not copy the private contact card (timed out)" : "Could not copy the private card (timed out)";
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
        property string errorOutput: ""
        property bool outputReady: false
        property bool errorReady: false
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

        stderr: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                actionProcess.errorOutput = String(text || "");
                actionProcess.errorReady = true;
                root.finishActionProcess();
            }
        }

    }

    Process {
        id: cueProcess

        property bool startPending: false

        onStarted: {
            startPending = false;
            cueStartTimeout.stop();
        }
        onExited: function(exitCode) {
            startPending = false;
            cueStartTimeout.stop();
            root.driveCue();
        }
    }

    // Invites contain the room secret. SplitParser emits a line without
    // retaining it in a read-only collector after we scrub `output`.
    Process {
        id: inviteProcess

        property string output: ""
        property bool waitingCard: false
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
            var waitingCardCopy = waitingCard;
            output = "";
            waitingCard = false;
            if (exitCode === 0) {
                root.copyOpaqueInvite(invite, waitingCardCopy);
            } else {
                root.notice = "";
                root.actionError = waitingCardCopy ? "Could not create the private contact card" : "Could not create a private card";
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
        property bool waitingCard: false
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
            var waitingCardCopy = waitingCard;
            // This is the sole temporary property that contains our own opaque
            // invite. Clear it as soon as the stdin-to-wl-copy bridge exits.
            payload = "";
            if (exitCode === 0) {
                root.notice = waitingCardCopy ? "Contact card copied — send it privately and leave this computer waiting." : "Private card copied";
            } else {
                root.notice = "";
                root.actionError = waitingCardCopy ? "Could not copy the private contact card" : "Could not copy the private card";
            }
            waitingCard = false;
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

        function setConfig(key: string, value: string) : string {
            return root.setConfig(key, value) ? "ok" : "busy";
        }

        function hangup() : string {
            return root.hangup() ? "ok" : "busy";
        }

        target: root.moduleName
    }

}
