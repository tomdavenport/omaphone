import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui

Panel {
    id: root

    readonly property color foreground: bar ? bar.foreground : Color.foreground
    readonly property color urgent: bar ? bar.urgent : Color.urgent
    readonly property color accent: Color.accent
    readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
    readonly property var phoneService: bar && bar.shell ? bar.shell.serviceFor(moduleName) : null
    readonly property var emptyStatus: ({
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
    readonly property var phoneStatus: phoneService ? phoneService.phoneStatus : emptyStatus
    readonly property bool statusLoaded: phoneService ? phoneService.statusLoaded : false
    readonly property string statusReadError: phoneService ? phoneService.statusReadError : ""
    readonly property string actionError: phoneService ? phoneService.actionError : ""
    readonly property string notice: phoneService ? phoneService.notice : ""
    readonly property string cueText: phoneService ? phoneService.cueText : ""
    readonly property bool inviteAndWaitPending: phoneService ? phoneService.inviteAndWaitPending : false
    readonly property int joinSuccessSequence: phoneService ? phoneService.joinSuccessSequence : 0
    property bool advancedOpen: false
    property bool pairOpen: false
    property string pairMode: "phone"
    property bool roomConfirmOpen: false
    property bool rotateConfirm: false
    property bool cursorActive: false
    property bool keyboardNavigationActive: false
    property string helpHoverAction: ""
    property int actionIndex: 0
    property string actionCursorId: ""
    property string lastSyncedRemoteAddress: ""
    property int observedJoinSuccessSequence: -1
    // Pointer and keyboard holds feed one desired-state process. If the user
    // releases while `ptt start` is still in flight, `ptt stop` is queued and
    // issued as soon as start exits.
    property bool pttPointerHeld: false
    property bool pttKeyboardHeld: false
    property bool pttAccessibleHeld: false
    readonly property string phase: String(phoneStatus.phase || "unconfigured")
    readonly property bool configured: phoneStatus.configured === true
    readonly property bool backendInstalled: phoneStatus.backendInstalled === true
    readonly property bool dependenciesReady: phoneStatus.dependenciesReady === true
    readonly property bool online: phoneStatus.online === true
    readonly property bool connected: phase === "connected"
    readonly property bool calling: phase === "calling"
    readonly property bool relaying: phase === "relay"
    readonly property bool groupCall: phoneStatus.groupCall === true
    readonly property int roomSize: typeof phoneStatus.roomSize === "number" && isFinite(phoneStatus.roomSize) ? Math.max(0, Math.min(10000, Math.floor(phoneStatus.roomSize))) : 0
    readonly property bool relayReady: phoneStatus.relayReady === true
    readonly property bool inSession: connected || calling || relaying
    readonly property bool hasPeer: phoneStatus.hasPeer === true && String(phoneStatus.pairedAddress || "") !== ""
    readonly property string peerKind: hasPeer && String(phoneStatus.peerKind || "") === "group" ? "group" : (hasPeer ? "direct" : "")
    readonly property bool groupPeer: peerKind === "group"
    readonly property bool selfPeer: phoneStatus.selfPeer === true
    readonly property string preferredRole: {
        var explicitRole = String(phoneStatus.preferredRole || "");
        if (["caller", "listener"].indexOf(explicitRole) >= 0)
            return explicitRole;

        if (!hasPeer)
            return "";

        return online || phase === "starting" || phase === "listening" ? "listener" : "caller";
    }
    readonly property bool listenerRole: preferredRole === "listener"
    readonly property bool waiting: listenerRole && online && (phase === "starting" || phase === "listening")
    readonly property string callStage: ["preparing", "opening-tor", "dialing"].indexOf(String(phoneStatus.callStage || "")) >= 0 ? String(phoneStatus.callStage) : ""
    readonly property int torProgress: typeof phoneStatus.torProgress === "number" && isFinite(phoneStatus.torProgress) ? Math.max(0, Math.min(100, Math.floor(phoneStatus.torProgress))) : 0
    readonly property string lastCallMessage: String(phoneStatus.lastCallMessage || "")
    readonly property bool pttHeld: pttPointerHeld || pttKeyboardHeld || pttAccessibleHeld
    readonly property bool actionBusy: phoneService ? phoneService.actionBusy : true
    readonly property bool commandBusy: phoneService ? phoneService.commandBusy : true
    readonly property bool clipboardBusy: phoneService ? phoneService.clipboardBusy : false
    readonly property var missingDependencies: Array.isArray(phoneStatus.missingDependencies) ? phoneStatus.missingDependencies : []
    readonly property bool onlyOptionalSnowflakeMissing: missingDependencies.length === 1 && String(missingDependencies[0]) === "snowflake-client"
    readonly property bool snowflakeAvailable: phoneStatus.snowflakeAvailable === true
    readonly property bool snowflakeEnabled: settingBool("snowflake", false)
    readonly property bool snowflakeBlocked: snowflakeEnabled && !snowflakeAvailable
    // Keep the normal phone visible for users updating from a backend that
    // reported the optional Snowflake client as a required dependency.
    readonly property bool ready: configured && backendInstalled && (dependenciesReady || onlyOptionalSnowflakeMissing)
    readonly property var visibleMessages: Array.isArray(phoneStatus.messages) ? phoneStatus.messages.slice(Math.max(0, phoneStatus.messages.length - 6)) : []
    readonly property bool editorActive: dialField.activeFocus || pairField.activeFocus || messageField.activeFocus
    readonly property bool dropdownActive: qualityDropdown.popupOpen || voiceDropdown.popupOpen || chimeDropdown.popupOpen
    readonly property var mainActions: {
        var actions = [];
        if (!root.ready) {
            if (!root.configured || !root.backendInstalled)
                actions.push("setup");

            if (root.missingDependencies.length > 0)
                actions.push("install");

            return actions;
        }
        if (root.advancedOpen && !root.inSession) {
            if (root.phase !== "starting") {
                actions.push("join-room");
                if (root.roomConfirmOpen)
                    actions.push("room-cancel", "room-start");
                else
                    actions.push("room");
            }
            if (String(root.phoneStatus.onion || "") !== "" && !root.groupPeer)
                actions.push("copy");

            actions.push("advanced", "call");
            actions.push("quality", "chime", "voice");
            if (root.snowflakeAvailable || root.snowflakeEnabled)
                actions.push("snowflake");

            actions.push("hmac", "audio");
            if (root.hasPeer)
                actions.push("clear-peer");

            if (root.visibleMessages.length > 0)
                actions.push("clear-chat");

            if (!root.online) {
                if (root.rotateConfirm)
                    actions.push("rotate-cancel", "rotate-now");
                else
                    actions.push("rotate");
            }
            return actions;
        }
        if (root.snowflakeBlocked && !root.inSession)
            actions.push("normal-tor");

        if (root.pairOpen && !root.inSession) {
            actions.push("add-phone", "add-cancel");
            return actions;
        }
        if (root.connected) {
            actions.push("ptt", "send", "hangup");
        } else if (root.calling) {
            actions.push("hangup");
        } else if (root.relaying) {
            if (root.relayReady && String(root.phoneStatus.onion || "") !== "")
                actions.push("copy");

            actions.push("hangup");
        } else if (root.selfPeer)
            actions.push("add-phone", "clear-peer");
        else if (root.groupPeer)
            actions.push("room-peer-call", "add-phone", "clear-peer");
        else if (root.hasPeer)
            actions.push("paired-primary", "role-switch");
        else
            actions.push("share-phone", "add-phone");
        if (!root.inSession)
            actions.push("advanced");

        return actions;
    }
    readonly property string heroTitle: {
        if (!statusLoaded)
            return "Omaphone";

        if (!ready)
            return "Set up Omaphone";

        if (phase === "starting")
            return "Opening a private line";

        if (phase === "listening")
            return groupPeer ? "Room invite saved" : (hasPeer ? "Waiting for paired phone" : "Waiting for a call");

        if (phase === "calling")
            return groupCall || groupPeer ? "Joining group" : "Calling paired phone";

        if (phase === "connected")
            return groupCall ? "Group call" : "Private call";

        if (phase === "testing")
            return "Testing audio";

        if (phase === "relay")
            return relayReady ? "Hosting a group" : "Starting group host";

        if (phase === "error")
            return "Needs attention";

        return "Omaphone";
    }
    readonly property string heroMeta: {
        if (!statusLoaded)
            return "Checking status";

        if (!ready) {
            if (missingDependencies.length > 0)
                return "Some calling tools are missing";

            return "A private push-to-talk phone";
        }
        if (phoneStatus.remoteTalking === true)
            return "Receiving voice";

        if (phoneStatus.localTalking === true || pttHeld)
            return "Recording voice";

        if (phase === "starting")
            return "Preparing private route";

        if (phase === "listening")
            return groupPeer ? "Rejoin it, or add your phone again" : "Leave this computer waiting";

        if (phase === "calling")
            return callProgressText();

        if (phase === "connected") {
            if (groupCall && roomSize > 0)
                return peopleLabel(roomSize) + " connected over Tor";

            return "Connected over Tor";
        }
        if (phase === "testing")
            return "Check your speakers and microphone";

        if (phase === "relay") {
            if (!relayReady)
                return "Connecting the room over Tor";

            return roomSize > 0 ? connectedLabel(roomSize) : "Ready for people to join";
        }
        if (phase === "error")
            return "Open the error below for details";

        return "Offline";
    }
    readonly property string heroDetail: {
        if (!statusLoaded)
            return "CHECKING";

        if (!ready)
            return "SETUP";

        if (phase === "connected")
            return "LIVE";

        if (phase === "listening")
            return "ONLINE";

        if (phase === "starting" || phase === "calling" || phase === "testing")
            return "WORKING";

        if (phase === "relay")
            return relayReady ? "HOSTING" : "WORKING";

        if (phase === "error")
            return "ERROR";

        return "OFFLINE";
    }
    readonly property string visibleError: {
        var value = actionError !== "" ? actionError : (statusReadError !== "" ? statusReadError : String(phoneStatus.lastError || ""));
        value = value.replace(/[\r\n]+/g, " ").trim();
        return value.length > 220 ? value.substring(0, 217) + "…" : value;
    }
    readonly property string barTooltip: {
        if (!statusLoaded)
            return "Omaphone · checking";

        if (!ready)
            return "Omaphone · setup needed";

        if (connected) {
            if (groupCall)
                return roomSize > 0 ? "Omaphone · group call · " + peopleLabel(roomSize) : "Omaphone · group call";

            return "Omaphone · private call connected";
        }
        if (calling)
            return groupCall || groupPeer ? "Omaphone · joining a group" : "Omaphone · calling";

        if (relaying) {
            if (!relayReady)
                return "Omaphone · starting group host";

            return roomSize > 0 ? "Omaphone · hosting · " + connectedLabel(roomSize) : "Omaphone · hosting a group";
        }
        if (online)
            return "Omaphone · online";

        return "Omaphone · offline";
    }

    function shortAddress(value) {
        var text = String(value || "").trim();
        if (text === "")
            return "Unknown caller";

        if (text.length <= 28)
            return text;

        return text.substring(0, 14) + "…" + text.substring(text.length - 10);
    }

    function callProgressText() {
        if (callStage === "opening-tor")
            return "Opening Tor " + String(torProgress) + "%";

        if (callStage === "dialing")
            return groupPeer ? "Waiting for room host" : "Waiting for other computer";

        return "Preparing private route";
    }

    function peopleLabel(count) {
        return count === 1 ? "1 person" : String(count) + " people";
    }

    function connectedLabel(count) {
        return count === 1 ? "1 connected" : String(count) + " connected";
    }

    function settingString(key, fallback) {
        var settings = phoneStatus.settings && typeof phoneStatus.settings === "object" ? phoneStatus.settings : ({
        });
        var value = settings[key];
        return value === undefined || value === null || String(value) === "" ? fallback : String(value);
    }

    function settingBool(key, fallback) {
        var settings = phoneStatus.settings && typeof phoneStatus.settings === "object" ? phoneStatus.settings : ({
        });
        var value = settings[key];
        return value === undefined || value === null ? fallback : value === true;
    }

    function syncAdvancedControls() {
        qualityDropdown.value = settingString("quality", "balanced");
        voiceDropdown.value = settingString("voiceEffect", "none");
        chimeDropdown.value = settingString("chime", "tone");
    }

    function syncDialAddress() {
        var address = String(phoneStatus.remoteAddress || "").trim();
        var currentAddress = String(dialField.text || "").trim();
        var addressIsValid = /^[a-z2-7]{56}\.onion$/i.test(address);
        if (!dialField.activeFocus && addressIsValid && (currentAddress === "" || currentAddress === lastSyncedRemoteAddress)) {
            dialField.text = address;
            lastSyncedRemoteAddress = address;
        } else if (currentAddress === address && addressIsValid) {
            lastSyncedRemoteAddress = address;
        }
    }

    function refresh() {
        if (phoneService)
            phoneService.refresh();

    }

    function setup() {
        if (phoneService)
            phoneService.setup();

    }

    function installDependencies() {
        if (phoneService)
            phoneService.installDependencies();

    }

    function goOnline() {
        if (phoneService)
            phoneService.goOnline();

    }

    function goOffline() {
        releasePtt();
        if (phoneService)
            phoneService.goOffline();

    }

    function toggleOnline() {
        if (phoneService)
            phoneService.toggleOnline();

    }

    function callAddress() {
        var address = String(dialField.text || "").trim();
        if (phoneService && phoneService.callAddress(address))
            dialField.text = "";
        else
            dialField.forceActiveFocus();
    }

    function joinPhone() {
        var invite = String(pairField.text || "").trim();
        if (invite === "") {
            pairField.forceActiveFocus();
            return ;
        }
        if (!phoneService || !phoneService.join(invite))
            pairField.forceActiveFocus();

    }

    function sharePhone() {
        if (!phoneService)
            return ;

        if (waiting)
            goOffline();
        else
            phoneService.inviteAndWait();
    }

    function callPeer() {
        if (phoneService)
            phoneService.callPeer();

    }

    function clearPeer() {
        if (phoneService)
            phoneService.clearPeer();

    }

    function activatePairedPrimary() {
        if (listenerRole) {
            if (waiting)
                goOffline();
            else
                goOnline();
        } else {
            callPeer();
        }
    }

    function switchPairedRole() {
        if (listenerRole)
            callPeer();
        else
            goOnline();
    }

    function copyInvite() {
        if (phoneService)
            phoneService.copyInvite();

    }

    function sendMessage() {
        var message = String(messageField.text || "").trim();
        if (message === "") {
            messageField.forceActiveFocus();
            return ;
        }
        if (phoneService && phoneService.sendMessage(message))
            messageField.text = "";

    }

    function hangup() {
        releasePtt();
        if (phoneService)
            phoneService.hangup();

    }

    function setConfig(key, value) {
        if (phoneService)
            phoneService.setConfig(key, value);

    }

    function toggleConfig(key, current) {
        if (phoneService)
            phoneService.toggleConfig(key, current);

    }

    function useNormalTor() {
        if (phoneService)
            phoneService.setConfig("snowflake", "false");

    }

    function toggleSnowflake() {
        if (!snowflakeEnabled && !snowflakeAvailable)
            return ;

        toggleConfig("snowflake", snowflakeEnabled);
    }

    function runAudioTest() {
        if (phoneService)
            phoneService.runAudioTest();

    }

    function startRelay() {
        roomConfirmOpen = false;
        if (phoneService)
            phoneService.startRelay();

    }

    function togglePair() {
        roomConfirmOpen = false;
        pairMode = "phone";
        pairOpen = !pairOpen;
        if (pairOpen)
            Qt.callLater(function() {
            pairField.forceActiveFocus();
            root.revealAction("add-phone");
        });
        else
            cancelAddPhone();
    }

    function cancelAddPhone() {
        var returnToRooms = pairMode === "room";
        pairField.text = "";
        pairOpen = false;
        pairMode = "phone";
        advancedOpen = returnToRooms;
        keyCatcher.forceActiveFocus();
        if (returnToRooms)
            Qt.callLater(function() {
            root.selectAction("join-room");
            root.revealAction("join-room");
        });

    }

    function openRoomJoin() {
        pairField.text = "";
        advancedOpen = false;
        roomConfirmOpen = false;
        rotateConfirm = false;
        pairMode = "room";
        pairOpen = true;
        Qt.callLater(function() {
            pairField.forceActiveFocus();
            root.revealAction("add-phone");
        });
    }

    function openRoomConfirm() {
        pairField.text = "";
        pairOpen = false;
        pairMode = "phone";
        roomConfirmOpen = true;
        rotateConfirm = false;
        Qt.callLater(function() {
            root.revealAction("room-start");
        });
    }

    function cancelRoomConfirm() {
        roomConfirmOpen = false;
        Qt.callLater(function() {
            root.revealAction("room");
        });
    }

    function toggleAdvanced() {
        advancedOpen = !advancedOpen;
        var showingAdvanced = advancedOpen;
        if (showingAdvanced) {
            pairField.text = "";
            pairOpen = false;
            pairMode = "phone";
        }
        roomConfirmOpen = false;
        rotateConfirm = false;
        Qt.callLater(function() {
            root.selectAction("advanced");
            panelFlick.contentY = 0;
            if (!showingAdvanced)
                root.revealAction("advanced");

        });
    }

    function rotateIdentity() {
        if (phoneService && phoneService.rotateIdentity())
            rotateConfirm = false;

    }

    function clearChat() {
        if (phoneService)
            phoneService.clearChat();

    }

    function requestPtt(start) {
        return phoneService ? phoneService.requestPtt(start) : false;
    }

    function beginPointerPtt() {
        if (!connected || phoneStatus.remoteTalking === true)
            return ;

        if (requestPtt(true))
            pttPointerHeld = true;

    }

    function endPointerPtt() {
        pttPointerHeld = false;
        if (!pttKeyboardHeld && !pttAccessibleHeld)
            requestPtt(false);

    }

    function beginKeyboardPtt() {
        if (!connected || phoneStatus.remoteTalking === true)
            return ;

        if (requestPtt(true))
            pttKeyboardHeld = true;

    }

    function endKeyboardPtt() {
        pttKeyboardHeld = false;
        if (!pttPointerHeld && !pttAccessibleHeld)
            requestPtt(false);

    }

    function beginAccessiblePtt() {
        if (!connected || phoneStatus.remoteTalking === true)
            return ;

        if (requestPtt(true)) {
            pttAccessibleHeld = true;
            accessiblePttRelease.restart();
        }
    }

    function endAccessiblePtt() {
        accessiblePttRelease.stop();
        pttAccessibleHeld = false;
        if (!pttPointerHeld && !pttKeyboardHeld)
            requestPtt(false);

    }

    function releasePtt() {
        accessiblePttRelease.stop();
        pttPointerHeld = false;
        pttKeyboardHeld = false;
        pttAccessibleHeld = false;
        requestPtt(false);
    }

    function messageText(message) {
        return message && message.text !== undefined ? String(message.text) : "";
    }

    function messageOutgoing(message) {
        return !!message && String(message.direction || "") === "outgoing";
    }

    function messageTime(message) {
        if (!message || !message.timestamp)
            return "";

        var stamp = new Date(String(message.timestamp));
        return isNaN(stamp.getTime()) ? "" : Qt.formatTime(stamp, "HH:mm");
    }

    function clampActionIndex() {
        if (mainActions.length === 0) {
            actionIndex = 0;
            actionCursorId = "";
            return ;
        }
        if (cursorActive && actionCursorId !== "") {
            var preservedIndex = mainActions.indexOf(actionCursorId);
            if (preservedIndex >= 0) {
                actionIndex = preservedIndex;
                return ;
            }
        }
        actionIndex = Math.max(0, Math.min(actionIndex, mainActions.length - 1));
        actionCursorId = String(mainActions[actionIndex] || "");
    }

    function selectAction(action) {
        var index = mainActions.indexOf(action);
        if (index < 0)
            return ;

        cursorActive = true;
        actionIndex = index;
        actionCursorId = action;
    }

    function actionHasCursor(action) {
        return cursorActive && mainActions[actionIndex] === action;
    }

    function handleHelpHover(action, hovered) {
        if (hovered) {
            keyboardNavigationActive = false;
            helpHoverAction = action;
            selectAction(action);
        } else if (helpHoverAction === action) {
            helpHoverAction = "";
        }
    }

    function helpVisible(action) {
        return helpHoverAction === action || (keyboardNavigationActive && actionHasCursor(action));
    }

    function moveAction(delta) {
        if (mainActions.length === 0)
            return ;

        cursorActive = true;
        keyboardNavigationActive = true;
        helpHoverAction = "";
        actionIndex = Math.max(0, Math.min(mainActions.length - 1, actionIndex + delta));
        var action = mainActions[actionIndex];
        actionCursorId = action;
        if (action === "call" && dialField.activeFocus)
            keyCatcher.forceActiveFocus();

        Qt.callLater(function() {
            root.revealAction(action);
        });
    }

    function itemForAction(action) {
        if (action === "setup")
            return setupButton;

        if (action === "install")
            return installButton;

        if (action === "normal-tor")
            return normalTorButton;

        if (action === "call")
            return callButton;

        if (action === "share-phone")
            return sharePhoneButton;

        if (action === "add-phone")
            return root.pairOpen ? pairButton : (root.selfPeer ? selfAddPhoneButton : (root.groupPeer ? roomPeerAddButton : pairToggleButton));

        if (action === "add-cancel")
            return pairCancelButton;

        if (action === "paired-primary")
            return pairedPrimaryButton;

        if (action === "room-peer-call")
            return roomPeerCallButton;

        if (action === "role-switch")
            return roleSwitchButton;

        if (action === "clear-peer")
            return root.advancedOpen ? advancedClearPeerButton : (root.groupPeer ? roomPeerClearButton : selfClearPeerButton);

        if (action === "room")
            return roomHostButton;

        if (action === "join-room")
            return roomJoinButton;

        if (action === "room-cancel")
            return roomCancelButton;

        if (action === "room-start")
            return roomStartButton;

        if (action === "ptt")
            return talkSurface;

        if (action === "send")
            return sendButton;

        if (action === "hangup") {
            if (root.calling)
                return callingHangupButton;

            if (root.relaying)
                return hostingStopButton;

            if (root.connected)
                return connectedHangupButton;

            return null;
        }
        if (action === "copy")
            return root.relaying ? hostingCopyButton : copyButton;

        if (action === "advanced")
            return advancedButton;

        if (action === "quality")
            return qualityDropdown;

        if (action === "chime")
            return chimeDropdown;

        if (action === "voice")
            return voiceDropdown;

        if (action === "snowflake")
            return snowflakeToggle;

        if (action === "hmac")
            return hmacToggle;

        if (action === "audio")
            return audioButton;

        if (action === "rotate")
            return rotateButton;

        if (action === "rotate-cancel")
            return rotateCancelButton;

        if (action === "rotate-now")
            return rotateNowButton;

        if (action === "clear-chat")
            return clearChatButton;

        return null;
    }

    function revealAction(action) {
        var item = itemForAction(action);
        if (!item || !item.visible)
            return ;

        var point = item.mapToItem(panelFlick.contentItem, 0, 0);
        var top = Math.max(0, point.y - Style.space(8));
        var bottom = point.y + item.height + Style.space(8);
        var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height);
        if (top < panelFlick.contentY)
            panelFlick.contentY = Math.max(0, Math.min(maxY, top));
        else if (bottom > panelFlick.contentY + panelFlick.height)
            panelFlick.contentY = Math.max(0, Math.min(maxY, bottom - panelFlick.height));
    }

    function activateAction() {
        if (mainActions.length === 0)
            return ;

        var action = mainActions[actionIndex];
        if (action === "setup") {
            setup();
        } else if (action === "install") {
            installDependencies();
        } else if (action === "normal-tor") {
            useNormalTor();
        } else if (action === "call") {
            if (String(dialField.text || "").trim() === "")
                dialField.forceActiveFocus();
            else
                callAddress();
        } else if (action === "share-phone") {
            sharePhone();
        } else if (action === "add-phone") {
            if (!pairOpen) {
                roomConfirmOpen = false;
                pairMode = "phone";
                pairOpen = true;
                Qt.callLater(function() {
                    pairField.forceActiveFocus();
                    root.revealAction("add-phone");
                });
            } else {
                joinPhone();
            }
        } else if (action === "add-cancel") {
            cancelAddPhone();
        } else if (action === "paired-primary") {
            activatePairedPrimary();
        } else if (action === "room-peer-call") {
            callPeer();
        } else if (action === "role-switch") {
            switchPairedRole();
        } else if (action === "clear-peer") {
            clearPeer();
        } else if (action === "ptt") {
            beginKeyboardPtt();
        } else if (action === "send") {
            if (String(messageField.text || "").trim() === "")
                messageField.forceActiveFocus();
            else
                sendMessage();
        } else if (action === "hangup")
            hangup();
        else if (action === "copy")
            copyInvite();
        else if (action === "room")
            openRoomConfirm();
        else if (action === "join-room")
            openRoomJoin();
        else if (action === "room-cancel")
            cancelRoomConfirm();
        else if (action === "room-start")
            startRelay();
        else if (action === "advanced")
            toggleAdvanced();
        else if (action === "quality")
            qualityDropdown.open();
        else if (action === "chime")
            chimeDropdown.open();
        else if (action === "voice")
            voiceDropdown.open();
        else if (action === "snowflake")
            toggleSnowflake();
        else if (action === "hmac")
            toggleConfig("hmac", hmacToggle.checked);
        else if (action === "audio")
            runAudioTest();
        else if (action === "rotate")
            rotateConfirm = true;
        else if (action === "rotate-cancel")
            rotateConfirm = false;
        else if (action === "rotate-now")
            rotateIdentity();
        else if (action === "clear-chat")
            clearChat();
    }

    function handleEditorKeys(event) {
        if (event.key === Qt.Key_Escape) {
            if (pairOpen)
                cancelAddPhone();
            else
                close();
            event.accepted = true;
        } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
            switchPanel((event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab ? -1 : 1);
            event.accepted = true;
        }
    }

    function closeOrCancel() {
        if (pairOpen)
            cancelAddPhone();
        else
            close();
    }

    function close() {
        releasePtt();
        pairField.text = "";
        pairOpen = false;
        pairMode = "phone";
        roomConfirmOpen = false;
        rotateConfirm = false;
        keyboardNavigationActive = false;
        helpHoverAction = "";
        root.controller.hide();
    }

    moduleName: "omaphone.phone"
    ipcTarget: "omaphone.phone"
    // The singleton service owns IPC and every backend process. This per-monitor
    // panel owns only presentation and local focus/hold state.
    manageIpc: false
    onMainActionsChanged: {
        clampActionIndex();
        if (cursorActive && actionCursorId !== "") {
            var actionToReveal = actionCursorId;
            Qt.callLater(function() {
                root.revealAction(actionToReveal);
            });
        }
    }
    onPhoneServiceChanged: {
        if (phoneService) {
            observedJoinSuccessSequence = phoneService.joinSuccessSequence;
            refresh();
            Qt.callLater(root.syncAdvancedControls);
            Qt.callLater(root.syncDialAddress);
        }
    }
    onJoinSuccessSequenceChanged: {
        if (observedJoinSuccessSequence < 0) {
            observedJoinSuccessSequence = joinSuccessSequence;
            return ;
        }
        if (joinSuccessSequence > observedJoinSuccessSequence) {
            pairField.text = "";
            pairOpen = false;
            pairMode = "phone";
            Qt.callLater(function() {
                keyCatcher.forceActiveFocus();
            });
        }
        observedJoinSuccessSequence = joinSuccessSequence;
    }
    onPhoneStatusChanged: {
        clampActionIndex();
        Qt.callLater(root.syncAdvancedControls);
        Qt.callLater(root.syncDialAddress);
        if (phoneStatus.remoteTalking === true && pttHeld)
            releasePtt();

    }
    onConnectedChanged: {
        if (!connected)
            releasePtt();

    }
    onInSessionChanged: {
        if (inSession) {
            advancedOpen = false;
            pairOpen = false;
            pairMode = "phone";
            roomConfirmOpen = false;
            rotateConfirm = false;
            panelFlick.contentY = 0;
        }
    }
    onVisibleChanged: {
        if (!visible) {
            releasePtt();
            keyboardNavigationActive = false;
            helpHoverAction = "";
        }
    }
    onOpenedChanged: {
        if (opened) {
            cursorActive = false;
            keyboardNavigationActive = false;
            helpHoverAction = "";
            actionIndex = 0;
            actionCursorId = mainActions.length > 0 ? String(mainActions[0]) : "";
            panelFlick.contentY = 0;
            refresh();
        } else {
            releasePtt();
            pairField.text = "";
            pairOpen = false;
            pairMode = "phone";
            roomConfirmOpen = false;
            rotateConfirm = false;
        }
    }
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight
    Component.onCompleted: refresh()
    Component.onDestruction: releasePtt()

    // Assistive activation has no release event. Treat it as a safe toggle and
    // force release after ten seconds even if the second activation never comes.
    Timer {
        id: accessiblePttRelease

        interval: 10000
        repeat: false
        onTriggered: root.endAccessiblePtt()
    }

    BarIconButton {
        id: button

        anchors.fill: parent
        bar: root.bar
        text: "󰏲"
        active: root.inSession || root.phoneStatus.remoteTalking === true
        dimmed: root.statusLoaded && !root.ready
        tooltipText: root.barTooltip
        Accessible.role: Accessible.Button
        Accessible.name: root.barTooltip
        Accessible.description: "Open the Omaphone push-to-talk phone"
        Accessible.focusable: true
        Accessible.onPressAction: root.toggle()
        onPressed: function(buttonCode) {
            if (buttonCode === Qt.MiddleButton)
                root.refresh();
            else if (buttonCode === Qt.RightButton && root.ready && !root.inSession)
                root.toggleOnline();
            else
                root.toggle();
        }
    }

    KeyboardPanel {
        id: panel

        anchorItem: button
        owner: root
        bar: root.bar
        open: root.opened
        focusTarget: keyCatcher
        contentWidth: panel.fittedContentWidth(Style.space(410))
        contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(700))
        onVisibleChanged: {
            if (!visible)
                root.releasePtt();

        }

        PanelKeyCatcher {
            id: keyCatcher

            anchors.fill: parent
            blocked: root.editorActive || root.dropdownActive
            onMoveRequested: function(dx, dy) {
                if (dy !== 0)
                    root.moveAction(dy);

            }
            onActivateRequested: root.activateAction()
            onCloseRequested: root.closeOrCancel()
            onTabRequested: function(direction) {
                root.switchPanel(direction);
            }
            onTextKey: function(text) {
                if (text === "r" || text === "R")
                    root.refresh();

            }
            onActiveFocusChanged: {
                if (!activeFocus && root.pttKeyboardHeld)
                    root.endKeyboardPtt();

            }
            // PanelKeyCatcher owns Enter/Space presses. Their releases end the
            // keyboard PTT hold just as pointer release ends a mouse hold.
            Keys.onReleased: function(event) {
                if (!root.pttKeyboardHeld)
                    return ;

                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                    root.endKeyboardPtt();
                    event.accepted = true;
                }
            }

            Flickable {
                id: panelFlick

                anchors.fill: parent
                contentWidth: width
                contentHeight: contentColumn.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.VerticalFlick
                interactive: contentHeight > height

                Column {
                    id: contentColumn

                    width: panelFlick.width
                    spacing: Style.space(12)

                    PanelHero {
                        width: parent.width
                        title: root.heroTitle
                        meta: root.heroMeta
                        detail: root.heroDetail
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        iconOpacity: root.ready ? 1 : 0.55

                        iconComponent: Component {
                            Item {
                                implicitWidth: Style.font.display
                                implicitHeight: Style.font.display
                                width: implicitWidth
                                height: implicitHeight

                                Text {
                                    anchors.fill: parent
                                    text: "󰏲"
                                    color: root.foreground
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.display
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                }

                            }

                        }

                    }

                    CursorSurface {
                        visible: root.visibleError !== ""
                        width: parent.width
                        implicitHeight: errorText.implicitHeight + Style.space(16)
                        current: true
                        foreground: root.urgent
                        accent: root.urgent

                        Text {
                            id: errorText

                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: Style.space(10)
                            anchors.rightMargin: Style.space(10)
                            text: root.visibleError
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                            wrapMode: Text.WordWrap
                        }

                    }

                    Text {
                        visible: root.notice !== "" && root.visibleError === ""
                        width: parent.width
                        text: root.notice
                        color: Qt.darker(root.foreground, 1.35)
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                    }

                    Text {
                        visible: root.cueText !== "" && root.cueText !== root.notice && root.cueText !== root.lastCallMessage
                        width: parent.width
                        text: root.cueText
                        color: Qt.darker(root.foreground, 1.25)
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        font.bold: true
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                    }

                    CursorSurface {
                        visible: root.lastCallMessage !== "" && root.lastCallMessage !== root.visibleError && !root.calling && !root.connected
                        width: parent.width
                        implicitHeight: lastCallColumn.implicitHeight + Style.space(18)
                        current: true
                        foreground: root.urgent
                        accent: root.urgent

                        Column {
                            id: lastCallColumn

                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: Style.space(10)
                            anchors.rightMargin: Style.space(10)
                            spacing: Style.space(5)

                            Text {
                                width: parent.width
                                text: root.lastCallMessage
                                color: root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.bodySmall
                                font.bold: true
                                wrapMode: Text.WordWrap
                            }

                            Text {
                                width: parent.width
                                text: root.groupPeer ? "Keep the room host online, then try again." : "Leave the other computer waiting, then try again."
                                color: Qt.darker(root.foreground, 1.25)
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                wrapMode: Text.WordWrap
                            }

                        }

                    }

                    Column {
                        id: setupColumn

                        visible: !root.ready
                        width: parent.width
                        spacing: Style.space(8)

                        Text {
                            width: parent.width
                            text: "Set up your private phone. Omaphone creates one stable private calling address and installs its checked, pinned phone engine."
                            color: Qt.darker(root.foreground, 1.35)
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                            wrapMode: Text.WordWrap
                        }

                        Button {
                            id: setupButton

                            visible: !root.configured || !root.backendInstalled
                            width: parent.width
                            text: root.commandBusy ? "Setting up…" : "Set up Omaphone"
                            iconText: "󰒓"
                            bordered: true
                            enabled: !root.commandBusy
                            foreground: root.foreground
                            accent: root.accent
                            fontFamily: root.fontFamily
                            hasCursor: root.actionHasCursor("setup")
                            onHovered: function(hovered) {
                                if (hovered)
                                    root.selectAction("setup");

                            }
                            onClicked: root.setup()
                            Accessible.role: Accessible.Button
                            Accessible.name: text
                            Accessible.onPressAction: root.setup()
                        }

                        Button {
                            id: installButton

                            visible: root.missingDependencies.length > 0
                            width: parent.width
                            text: root.commandBusy ? "Installing…" : "Install missing tools"
                            iconText: "󰏔"
                            bordered: true
                            enabled: !root.commandBusy
                            foreground: root.foreground
                            accent: root.accent
                            fontFamily: root.fontFamily
                            hasCursor: root.actionHasCursor("install")
                            onHovered: function(hovered) {
                                if (hovered)
                                    root.selectAction("install");

                            }
                            onClicked: root.installDependencies()
                            Accessible.role: Accessible.Button
                            Accessible.name: text
                            Accessible.onPressAction: root.installDependencies()
                        }

                        Text {
                            visible: root.missingDependencies.length > 0
                            width: parent.width
                            text: "Missing: " + root.missingDependencies.join(", ")
                            color: Qt.darker(root.foreground, 1.5)
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            wrapMode: Text.WordWrap
                        }

                    }

                    Column {
                        id: mainColumn

                        visible: root.ready
                        width: parent.width
                        spacing: Style.space(10)

                        CursorSurface {
                            id: snowflakeRecoveryCard

                            visible: root.snowflakeBlocked && !root.inSession && !root.advancedOpen
                            width: parent.width
                            implicitHeight: snowflakeRecoveryColumn.implicitHeight + Style.space(18)
                            current: true
                            foreground: root.accent
                            accent: root.accent

                            Column {
                                id: snowflakeRecoveryColumn

                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.leftMargin: Style.space(10)
                                anchors.rightMargin: Style.space(10)
                                spacing: Style.space(7)

                                Text {
                                    width: parent.width
                                    text: "Snowflake is optional. Normal Tor works without it."
                                    color: root.foreground
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.body
                                    font.bold: true
                                    wrapMode: Text.WordWrap
                                }

                                Text {
                                    width: parent.width
                                    text: "The optional Snowflake client is not installed. Switch it off to keep using Omaphone."
                                    color: Qt.darker(root.foreground, 1.35)
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.bodySmall
                                    wrapMode: Text.WordWrap
                                }

                                Button {
                                    id: normalTorButton

                                    width: parent.width
                                    text: root.commandBusy ? "Switching…" : "Use normal Tor"
                                    iconText: "󰖩"
                                    bordered: true
                                    enabled: !root.commandBusy && !root.inSession
                                    foreground: root.foreground
                                    accent: root.accent
                                    fontFamily: root.fontFamily
                                    hasCursor: root.actionHasCursor("normal-tor")
                                    onHovered: function(hovered) {
                                        if (hovered)
                                            root.selectAction("normal-tor");

                                    }
                                    onClicked: root.useNormalTor()
                                    Accessible.role: Accessible.Button
                                    Accessible.name: "Use normal Tor"
                                    Accessible.description: "Turn off the unavailable optional Snowflake transport and keep using Omaphone"
                                    Accessible.onPressAction: root.useNormalTor()
                                }

                            }

                        }

                        CursorSurface {
                            visible: root.selfPeer && !root.pairOpen && !root.inSession && !root.advancedOpen
                            width: parent.width
                            implicitHeight: selfPeerColumn.implicitHeight + Style.space(18)
                            current: true
                            foreground: root.urgent
                            accent: root.urgent

                            Column {
                                id: selfPeerColumn

                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.leftMargin: Style.space(10)
                                anchors.rightMargin: Style.space(10)
                                spacing: Style.space(7)

                                Text {
                                    width: parent.width
                                    text: "This computer was paired with itself. No harm done."
                                    color: root.foreground
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.body
                                    font.bold: true
                                    wrapMode: Text.WordWrap
                                }

                                Text {
                                    width: parent.width
                                    text: "Add the contact card copied from the other computer, or clear this pairing."
                                    color: Qt.darker(root.foreground, 1.35)
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.bodySmall
                                    wrapMode: Text.WordWrap
                                }

                                Button {
                                    id: selfAddPhoneButton

                                    width: parent.width
                                    text: root.pairOpen ? "Cancel" : "Add the other phone"
                                    iconText: root.pairOpen ? "󰅖" : "󰌷"
                                    bordered: true
                                    enabled: !root.commandBusy
                                    foreground: root.foreground
                                    accent: root.accent
                                    fontFamily: root.fontFamily
                                    hasCursor: root.actionHasCursor("add-phone") && !root.pairOpen
                                    onHovered: function(hovered) {
                                        if (hovered)
                                            root.selectAction("add-phone");

                                    }
                                    onClicked: root.togglePair()
                                    Accessible.role: Accessible.Button
                                    Accessible.name: text
                                    Accessible.onPressAction: root.togglePair()
                                }

                                Button {
                                    id: selfClearPeerButton

                                    width: parent.width
                                    text: "Clear pairing"
                                    iconText: "󰆴"
                                    enabled: !root.commandBusy
                                    foreground: root.urgent
                                    accent: root.urgent
                                    fontFamily: root.fontFamily
                                    hasCursor: root.actionHasCursor("clear-peer")
                                    onHovered: function(hovered) {
                                        if (hovered)
                                            root.selectAction("clear-peer");

                                    }
                                    onClicked: root.clearPeer()
                                    Accessible.role: Accessible.Button
                                    Accessible.name: "Clear pairing"
                                    Accessible.onPressAction: root.clearPeer()
                                }

                            }

                        }

                        Column {
                            visible: !root.selfPeer && !root.hasPeer && !root.pairOpen && !root.inSession && !root.advancedOpen
                            width: parent.width
                            spacing: Style.space(7)

                            Button {
                                id: sharePhoneButton

                                width: parent.width
                                text: root.waiting ? "Stop waiting" : (root.inviteAndWaitPending ? "Preparing…" : "Share my phone")
                                iconText: root.waiting ? "󰖪" : "󰆏"
                                bordered: true
                                enabled: root.waiting ? (!root.actionBusy && !root.clipboardBusy) : (!root.commandBusy && !root.snowflakeBlocked)
                                foreground: root.foreground
                                accent: root.accent
                                fontFamily: root.fontFamily
                                hasCursor: root.actionHasCursor("share-phone")
                                onHovered: function(hovered) {
                                    if (hovered)
                                        root.selectAction("share-phone");

                                }
                                onClicked: root.sharePhone()
                                Accessible.role: Accessible.Button
                                Accessible.name: text
                                Accessible.description: root.waiting ? "Stop this computer waiting for a call" : "Copies a private contact card and waits"
                                Accessible.onPressAction: root.sharePhone()
                            }

                            Text {
                                width: parent.width
                                text: root.waiting ? "This computer is waiting. Leave it open while the other computer connects." : "Copies a private contact card and waits"
                                color: Qt.darker(root.foreground, 1.35)
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.bodySmall
                                horizontalAlignment: Text.AlignHCenter
                                wrapMode: Text.WordWrap
                            }

                            Button {
                                id: pairToggleButton

                                width: parent.width
                                text: root.pairOpen ? "Cancel" : "Add a phone"
                                iconText: root.pairOpen ? "󰅖" : "󰌷"
                                leftAlign: true
                                enabled: !root.commandBusy
                                foreground: root.foreground
                                accent: root.accent
                                fontFamily: root.fontFamily
                                hasCursor: root.actionHasCursor("add-phone") && !root.pairOpen
                                onHovered: function(hovered) {
                                    if (hovered)
                                        root.selectAction("add-phone");

                                }
                                onClicked: root.togglePair()
                                Accessible.role: Accessible.Button
                                Accessible.name: text
                                Accessible.description: "Add the other computer from its private contact card"
                                Accessible.onPressAction: root.togglePair()
                            }

                        }

                        Column {
                            visible: !root.selfPeer && root.groupPeer && !root.pairOpen && !root.inSession && !root.advancedOpen
                            width: parent.width
                            spacing: Style.space(7)

                            PanelSectionHeader {
                                text: "SAVED ROOM"
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                            }

                            Text {
                                width: parent.width
                                text: "This room invite occupies the one saved-call slot. Rejoin while its host is online, or add a phone to replace it."
                                color: Qt.darker(root.foreground, 1.35)
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.bodySmall
                                horizontalAlignment: Text.AlignHCenter
                                wrapMode: Text.WordWrap
                            }

                            Button {
                                id: roomPeerCallButton

                                width: parent.width
                                text: "Rejoin room"
                                iconText: "󰌷"
                                bordered: true
                                enabled: !root.commandBusy
                                foreground: root.foreground
                                accent: root.accent
                                fontFamily: root.fontFamily
                                hasCursor: root.actionHasCursor("room-peer-call")
                                onHovered: function(hovered) {
                                    if (hovered)
                                        root.selectAction("room-peer-call");

                                }
                                onClicked: root.callPeer()
                                Accessible.role: Accessible.Button
                                Accessible.name: "Rejoin saved room"
                                Accessible.description: "Connect while the room host is still online"
                                Accessible.onPressAction: root.callPeer()
                            }

                            Button {
                                id: roomPeerAddButton

                                width: parent.width
                                text: "Add a phone instead"
                                iconText: "󰏲"
                                leftAlign: true
                                enabled: !root.commandBusy
                                foreground: root.foreground
                                accent: root.accent
                                fontFamily: root.fontFamily
                                hasCursor: root.actionHasCursor("add-phone")
                                onHovered: function(hovered) {
                                    if (hovered)
                                        root.selectAction("add-phone");

                                }
                                onClicked: root.togglePair()
                                Accessible.role: Accessible.Button
                                Accessible.name: "Add a phone instead"
                                Accessible.description: "Replace the saved room with a phone's private contact card"
                                Accessible.onPressAction: root.togglePair()
                            }

                            Button {
                                id: roomPeerClearButton

                                width: parent.width
                                text: "Clear room invite"
                                iconText: "󰆴"
                                enabled: !root.commandBusy
                                foreground: root.urgent
                                accent: root.urgent
                                fontFamily: root.fontFamily
                                hasCursor: root.actionHasCursor("clear-peer")
                                onHovered: function(hovered) {
                                    if (hovered)
                                        root.selectAction("clear-peer");

                                }
                                onClicked: root.clearPeer()
                                Accessible.role: Accessible.Button
                                Accessible.name: "Clear saved room invite"
                                Accessible.description: "Remove the saved room address and call key from this phone"
                                Accessible.onPressAction: root.clearPeer()
                            }

                        }

                        Column {
                            visible: !root.selfPeer && root.hasPeer && !root.groupPeer && !root.pairOpen && !root.inSession && !root.advancedOpen
                            width: parent.width
                            spacing: Style.space(7)

                            PanelSectionHeader {
                                text: "PAIRED PHONE"
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                            }

                            Text {
                                width: parent.width
                                text: root.listenerRole ? (root.waiting ? "Waiting for the paired phone" : "This computer usually waits") : "This computer usually connects"
                                color: Qt.darker(root.foreground, 1.35)
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.bodySmall
                                horizontalAlignment: Text.AlignHCenter
                                wrapMode: Text.WordWrap
                            }

                            Button {
                                id: pairedPrimaryButton

                                width: parent.width
                                text: root.listenerRole ? (root.waiting ? "Stop waiting" : "Wait for paired phone") : "Call paired phone"
                                iconText: root.listenerRole ? (root.waiting ? "󰖪" : "󰖩") : "󰏲"
                                bordered: true
                                enabled: root.listenerRole && root.waiting ? (!root.actionBusy && !root.clipboardBusy) : (!root.commandBusy && (root.listenerRole ? !root.snowflakeBlocked : true))
                                foreground: root.foreground
                                accent: root.accent
                                fontFamily: root.fontFamily
                                hasCursor: root.actionHasCursor("paired-primary")
                                onHovered: function(hovered) {
                                    if (hovered)
                                        root.selectAction("paired-primary");

                                }
                                onClicked: root.activatePairedPrimary()
                                Accessible.role: Accessible.Button
                                Accessible.name: text
                                Accessible.onPressAction: root.activatePairedPrimary()
                            }

                            Button {
                                id: roleSwitchButton

                                width: parent.width
                                text: root.listenerRole ? "Connect from this computer instead" : "Wait on this computer instead"
                                iconText: root.listenerRole ? "󰏲" : "󰖩"
                                leftAlign: true
                                enabled: !root.commandBusy && (root.listenerRole || !root.snowflakeBlocked)
                                foreground: root.foreground
                                accent: root.accent
                                fontFamily: root.fontFamily
                                hasCursor: root.actionHasCursor("role-switch")
                                onHovered: function(hovered) {
                                    if (hovered)
                                        root.selectAction("role-switch");

                                }
                                onClicked: root.switchPairedRole()
                                Accessible.role: Accessible.Button
                                Accessible.name: text
                                Accessible.description: "Switch which computer waits and which computer connects"
                                Accessible.onPressAction: root.switchPairedRole()
                            }

                        }

                        Column {
                            visible: root.pairOpen && !root.inSession && !root.advancedOpen
                            width: parent.width
                            spacing: Style.space(7)

                            PanelSectionHeader {
                                text: root.pairMode === "room" ? "JOIN A ROOM" : "ADD A PHONE"
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                            }

                            Text {
                                width: parent.width
                                text: root.pairMode === "room" ? (root.groupPeer ? "This replaces the saved room invite and call key." : (root.hasPeer ? "This replaces your paired phone and call key until you add that phone's contact card again." : "A room invite becomes this phone's saved call until you add a phone later.")) : (root.groupPeer ? "This replaces the saved room invite and call key." : (root.hasPeer ? "This replaces the current paired phone and call key." : "A private contact card contains this phone's address and encryption key. Send it only to the person you want to call."))
                                color: root.pairMode === "room" || root.hasPeer ? root.urgent : Qt.darker(root.foreground, 1.35)
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                wrapMode: Text.WordWrap
                            }

                            TextField {
                                id: pairField

                                width: parent.width
                                placeholderText: root.pairMode === "room" ? "Paste the room invite" : "Paste their private contact card"
                                password: true
                                foreground: root.foreground
                                accent: root.accent
                                enabled: !root.commandBusy
                                onAccepted: root.joinPhone()
                                Keys.onPressed: function(event) {
                                    root.handleEditorKeys(event);
                                }
                                Accessible.name: placeholderText
                                Accessible.description: root.hasPeer ? "Connecting replaces the current saved call and call key" : ""
                            }

                            Row {
                                width: parent.width
                                spacing: Style.space(7)

                                Button {
                                    id: pairButton

                                    width: (parent.width - parent.spacing) / 2
                                    text: root.pairMode === "room" ? (root.hasPeer ? "Replace & join" : "Join room") : (root.hasPeer ? "Replace & connect" : "Add & connect")
                                    bordered: true
                                    enabled: !root.commandBusy && String(pairField.text || "").trim() !== ""
                                    foreground: root.foreground
                                    accent: root.accent
                                    fontFamily: root.fontFamily
                                    hasCursor: root.actionHasCursor("add-phone")
                                    onHovered: function(hovered) {
                                        if (hovered)
                                            root.selectAction("add-phone");

                                    }
                                    onClicked: root.joinPhone()
                                    Accessible.role: Accessible.Button
                                    Accessible.name: text
                                    Accessible.description: root.hasPeer ? "Replace the current saved call and call key with this card, then connect" : (root.pairMode === "room" ? "Save this room invite and connect" : "Save this private contact card and connect")
                                    Accessible.onPressAction: root.joinPhone()
                                }

                                Button {
                                    id: pairCancelButton

                                    width: (parent.width - parent.spacing) / 2
                                    text: "Cancel"
                                    bordered: true
                                    enabled: !root.commandBusy
                                    foreground: root.foreground
                                    accent: root.accent
                                    fontFamily: root.fontFamily
                                    hasCursor: root.actionHasCursor("add-cancel")
                                    onHovered: function(hovered) {
                                        if (hovered)
                                            root.selectAction("add-cancel");

                                    }
                                    onClicked: root.cancelAddPhone()
                                    Accessible.role: Accessible.Button
                                    Accessible.name: root.pairMode === "room" ? "Cancel joining room" : "Cancel adding phone"
                                    Accessible.onPressAction: root.cancelAddPhone()
                                }

                            }

                        }

                        Column {
                            id: roomColumn

                            visible: !root.inSession && root.phase !== "starting" && root.advancedOpen
                            width: parent.width
                            spacing: Style.space(7)

                            PanelSeparator {
                                foreground: root.foreground
                            }

                            PanelSectionHeader {
                                text: "SMALL GROUP · EXPERIMENTAL"
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                            }

                            Text {
                                width: parent.width
                                text: "Join with a host's room invite, or use this computer as the relay. Hosting needs no public server or port forwarding."
                                color: Qt.darker(root.foreground, 1.35)
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.bodySmall
                                wrapMode: Text.WordWrap
                            }

                            Button {
                                id: roomJoinButton

                                width: parent.width
                                text: "Join a room"
                                iconText: "󰌷"
                                leftAlign: true
                                bordered: true
                                enabled: !root.commandBusy
                                foreground: root.foreground
                                accent: root.accent
                                fontFamily: root.fontFamily
                                hasCursor: root.actionHasCursor("join-room")
                                onHovered: function(hovered) {
                                    root.handleHelpHover("join-room", hovered);
                                }
                                onClicked: root.openRoomJoin()
                                Accessible.role: Accessible.Button
                                Accessible.name: "Join a room"
                                Accessible.description: root.hasPeer ? "Paste a host's room invite; it replaces the current saved call and call key" : "Paste a private room invite from its host"
                                Accessible.onPressAction: root.openRoomJoin()

                                PanelToolTip {
                                    visible: root.helpVisible("join-room")
                                    text: "Paste the private room invite from its host."
                                    panelForeground: root.foreground
                                    fontFamily: root.fontFamily
                                }

                            }

                            Button {
                                id: roomHostButton

                                visible: !root.roomConfirmOpen
                                width: parent.width
                                text: "Host a group on this computer"
                                iconText: "󰑃"
                                leftAlign: true
                                bordered: true
                                enabled: !root.commandBusy
                                foreground: root.foreground
                                accent: root.accent
                                fontFamily: root.fontFamily
                                hasCursor: root.actionHasCursor("room")
                                onHovered: function(hovered) {
                                    if (hovered)
                                        root.selectAction("room");

                                }
                                onClicked: root.openRoomConfirm()
                                Accessible.role: Accessible.Button
                                Accessible.name: "Host a small group on this computer"
                                Accessible.description: "Experimental; this computer stays online as a relay and cannot join the conversation"
                                Accessible.onPressAction: root.openRoomConfirm()
                            }

                            CursorSurface {
                                visible: root.roomConfirmOpen
                                width: parent.width
                                implicitHeight: roomConfirmColumn.implicitHeight + Style.space(18)
                                current: true
                                foreground: root.accent
                                accent: root.accent

                                Column {
                                    id: roomConfirmColumn

                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.leftMargin: Style.space(9)
                                    anchors.rightMargin: Style.space(9)
                                    spacing: Style.space(6)

                                    Text {
                                        width: parent.width
                                        text: "Host from this computer?"
                                        color: root.foreground
                                        font.family: root.fontFamily
                                        font.pixelSize: Style.font.body
                                        font.bold: true
                                    }

                                    Text {
                                        width: parent.width
                                        text: "Keep it awake. This Omaphone only passes messages, so join from a second device if you want to talk too."
                                        color: root.foreground
                                        font.family: root.fontFamily
                                        font.pixelSize: Style.font.bodySmall
                                        wrapMode: Text.WordWrap
                                    }

                                    Text {
                                        width: parent.width
                                        text: "After it starts, Omaphone makes a fresh key for this room. Copy the room invite and send the same invite privately to everyone."
                                        color: Qt.darker(root.foreground, 1.35)
                                        font.family: root.fontFamily
                                        font.pixelSize: Style.font.caption
                                        wrapMode: Text.WordWrap
                                    }

                                    Row {
                                        width: parent.width
                                        spacing: Style.space(7)

                                        Button {
                                            id: roomCancelButton

                                            width: (parent.width - parent.spacing) / 2
                                            text: "Cancel"
                                            bordered: true
                                            foreground: root.foreground
                                            accent: root.accent
                                            fontFamily: root.fontFamily
                                            hasCursor: root.actionHasCursor("room-cancel")
                                            onHovered: function(hovered) {
                                                if (hovered)
                                                    root.selectAction("room-cancel");

                                            }
                                            onClicked: root.cancelRoomConfirm()
                                            Accessible.role: Accessible.Button
                                            Accessible.name: "Cancel group hosting"
                                            Accessible.onPressAction: root.cancelRoomConfirm()
                                        }

                                        Button {
                                            id: roomStartButton

                                            width: (parent.width - parent.spacing) / 2
                                            text: "Start hosting"
                                            bordered: true
                                            enabled: !root.commandBusy
                                            foreground: root.foreground
                                            accent: root.accent
                                            fontFamily: root.fontFamily
                                            hasCursor: root.actionHasCursor("room-start")
                                            onHovered: function(hovered) {
                                                if (hovered)
                                                    root.selectAction("room-start");

                                            }
                                            onClicked: root.startRelay()
                                            Accessible.role: Accessible.Button
                                            Accessible.name: "Start hosting the group"
                                            Accessible.description: "This computer becomes the relay and cannot join the conversation"
                                            Accessible.onPressAction: root.startRelay()
                                        }

                                    }

                                }

                            }

                        }

                        Column {
                            visible: root.calling
                            width: parent.width
                            spacing: Style.space(8)

                            Text {
                                width: parent.width
                                text: root.callProgressText()
                                color: root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.subtitle
                                font.bold: true
                                horizontalAlignment: Text.AlignHCenter
                            }

                            Text {
                                width: parent.width
                                text: root.groupPeer ? "The room host must stay online. This computer connects." : "The other computer stays waiting. Only this computer connects."
                                color: Qt.darker(root.foreground, 1.35)
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.bodySmall
                                horizontalAlignment: Text.AlignHCenter
                                wrapMode: Text.WordWrap
                            }

                            Button {
                                id: callingHangupButton

                                width: parent.width
                                text: "Hang up"
                                iconText: "󰅙"
                                bordered: true
                                enabled: !root.actionBusy
                                foreground: root.urgent
                                accent: root.urgent
                                fontFamily: root.fontFamily
                                hasCursor: root.actionHasCursor("hangup")
                                onHovered: function(hovered) {
                                    if (hovered)
                                        root.selectAction("hangup");

                                }
                                onClicked: root.hangup()
                                Accessible.role: Accessible.Button
                                Accessible.name: "Hang up"
                                Accessible.onPressAction: root.hangup()
                            }

                        }

                        Column {
                            visible: root.relaying
                            width: parent.width
                            spacing: Style.space(8)

                            Text {
                                width: parent.width
                                text: !root.relayReady ? "Starting the room host…" : (root.roomSize > 0 ? root.connectedLabel(root.roomSize) : "Room is ready")
                                color: root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.subtitle
                                font.bold: true
                                horizontalAlignment: Text.AlignHCenter
                            }

                            Text {
                                width: parent.width
                                text: root.relayReady ? "This computer is the relay only. Keep it awake, and join from a second device if you want to talk too." : "Tor is opening the room. This can take a minute."
                                color: Qt.darker(root.foreground, 1.35)
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.bodySmall
                                horizontalAlignment: Text.AlignHCenter
                                wrapMode: Text.WordWrap
                            }

                            Button {
                                id: hostingCopyButton

                                width: parent.width
                                text: !root.relayReady || String(root.phoneStatus.onion || "") === "" ? "Preparing room invite…" : (root.clipboardBusy ? "Copying…" : "Copy room invite")
                                iconText: "󰆏"
                                bordered: true
                                enabled: root.relayReady && String(root.phoneStatus.onion || "") !== "" && !root.actionBusy && !root.clipboardBusy
                                foreground: root.foreground
                                accent: root.accent
                                fontFamily: root.fontFamily
                                hasCursor: root.actionHasCursor("copy")
                                onHovered: function(hovered) {
                                    if (hovered)
                                        root.selectAction("copy");

                                }
                                onClicked: root.copyInvite()
                                Accessible.role: Accessible.Button
                                Accessible.name: text
                                Accessible.description: "Copy the private invite to share with every participant"
                                Accessible.onPressAction: root.copyInvite()
                            }

                            Text {
                                visible: root.relayReady
                                width: parent.width
                                text: "On every participant's computer: Advanced → Join a room → paste the room invite → confirm the join. Share the same invite privately with everyone."
                                color: Qt.darker(root.foreground, 1.35)
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                horizontalAlignment: Text.AlignHCenter
                                wrapMode: Text.WordWrap
                            }

                            Button {
                                id: hostingStopButton

                                width: parent.width
                                text: "Stop hosting"
                                iconText: "󰇙"
                                bordered: true
                                enabled: !root.actionBusy
                                foreground: root.urgent
                                accent: root.urgent
                                fontFamily: root.fontFamily
                                hasCursor: root.actionHasCursor("hangup")
                                onHovered: function(hovered) {
                                    if (hovered)
                                        root.selectAction("hangup");

                                }
                                onClicked: root.hangup()
                                Accessible.role: Accessible.Button
                                Accessible.name: "Stop hosting"
                                Accessible.description: "Stop passing messages for this group"
                                Accessible.onPressAction: root.hangup()
                            }

                        }

                        Column {
                            id: connectedColumn

                            visible: root.connected
                            width: parent.width
                            spacing: Style.space(8)
                            onVisibleChanged: {
                                if (!visible)
                                    root.releasePtt();

                            }

                            CursorSurface {
                                id: talkSurface

                                width: parent.width
                                implicitHeight: Style.space(96)
                                hasCursor: root.actionHasCursor("ptt")
                                current: root.pttHeld || root.phoneStatus.localTalking === true
                                bordered: true
                                foreground: root.foreground
                                accent: root.accent
                                Accessible.role: Accessible.Button
                                Accessible.name: root.phoneStatus.remoteTalking === true ? (root.groupCall ? "Someone else is talking" : "Other person is talking") : (root.pttAccessibleHeld ? "Recording voice; activate again to send" : (root.pttHeld ? "Recording voice; release to send" : "Hold to talk"))
                                Accessible.description: "Hold with a pointer or keyboard; assistive activation toggles recording with a ten second safety release"
                                Accessible.focusable: true
                                Accessible.focused: hasCursor
                                Accessible.pressed: root.pttHeld
                                Accessible.onPressAction: {
                                    if (root.pttAccessibleHeld)
                                        root.endAccessiblePtt();
                                    else
                                        root.beginAccessiblePtt();
                                }

                                Column {
                                    anchors.centerIn: parent
                                    spacing: Style.space(3)

                                    Text {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: root.phoneStatus.remoteTalking === true ? (root.groupCall ? "SOMEONE IS TALKING" : "THEY ARE TALKING") : ((root.pttHeld || root.phoneStatus.localTalking === true) ? "RECORDING — RELEASE TO SEND" : "HOLD TO TALK")
                                        color: root.foreground
                                        font.family: root.fontFamily
                                        font.pixelSize: Style.font.subtitle
                                        font.bold: true
                                    }

                                    Text {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: root.phoneStatus.remoteTalking === true ? "Listen now; reply when they finish" : "Hold to record. Release to send."
                                        color: Qt.darker(root.foreground, 1.4)
                                        font.family: root.fontFamily
                                        font.pixelSize: Style.font.caption
                                    }

                                }

                                MouseArea {
                                    id: talkMouse

                                    anchors.fill: parent
                                    acceptedButtons: Qt.LeftButton
                                    hoverEnabled: true
                                    preventStealing: true
                                    cursorShape: Qt.PointingHandCursor
                                    enabled: root.connected && root.phoneStatus.remoteTalking !== true
                                    onEntered: root.selectAction("ptt")
                                    onPressed: root.beginPointerPtt()
                                    onReleased: root.endPointerPtt()
                                    onCanceled: root.endPointerPtt()
                                    onExited: {
                                        if (pressed)
                                            root.endPointerPtt();

                                    }
                                    onPressedChanged: {
                                        if (!pressed && root.pttPointerHeld)
                                            root.endPointerPtt();

                                    }
                                }

                            }

                            Row {
                                width: parent.width
                                spacing: Style.space(7)

                                TextField {
                                    id: messageField

                                    width: parent.width - sendButton.width - parent.spacing
                                    placeholderText: "Message"
                                    foreground: root.foreground
                                    accent: root.accent
                                    enabled: !root.commandBusy
                                    onAccepted: root.sendMessage()
                                    Keys.onPressed: function(event) {
                                        root.handleEditorKeys(event);
                                    }
                                }

                                Button {
                                    id: sendButton

                                    text: "Send"
                                    iconText: "󰒊"
                                    bordered: true
                                    enabled: !root.commandBusy && String(messageField.text || "").trim() !== ""
                                    foreground: root.foreground
                                    accent: root.accent
                                    fontFamily: root.fontFamily
                                    hasCursor: root.actionHasCursor("send")
                                    onHovered: function(hovered) {
                                        if (hovered)
                                            root.selectAction("send");

                                    }
                                    onClicked: root.sendMessage()
                                    Accessible.role: Accessible.Button
                                    Accessible.name: "Send message"
                                    Accessible.onPressAction: root.sendMessage()
                                }

                            }

                            Button {
                                id: connectedHangupButton

                                width: parent.width
                                text: "Hang up"
                                iconText: "󰅙"
                                bordered: true
                                enabled: !root.actionBusy
                                foreground: root.urgent
                                accent: root.urgent
                                fontFamily: root.fontFamily
                                hasCursor: root.actionHasCursor("hangup")
                                onHovered: function(hovered) {
                                    if (hovered)
                                        root.selectAction("hangup");

                                }
                                onClicked: root.hangup()
                                Accessible.role: Accessible.Button
                                Accessible.name: "Hang up"
                                Accessible.onPressAction: root.hangup()
                            }

                        }

                        Column {
                            visible: root.visibleMessages.length > 0 && !root.advancedOpen
                            width: parent.width
                            spacing: Style.space(6)

                            PanelSectionHeader {
                                text: "RECENT CHAT"
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                            }

                            Repeater {
                                model: root.visibleMessages

                                delegate: Item {
                                    required property var modelData

                                    width: parent.width
                                    implicitHeight: bubble.implicitHeight

                                    BorderSurface {
                                        id: bubble

                                        x: root.messageOutgoing(modelData) ? parent.width - width : 0
                                        width: Math.max(Style.space(110), parent.width * 0.82)
                                        implicitHeight: bubbleColumn.implicitHeight + Style.space(12)
                                        color: root.messageOutgoing(modelData) ? Style.selectedFillFor(root.foreground, root.accent) : Style.hoverFillFor(root.foreground, root.accent)
                                        borderSpec: Border.none()
                                        radius: Style.cornerRadius

                                        Column {
                                            id: bubbleColumn

                                            anchors.left: parent.left
                                            anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            anchors.leftMargin: Style.space(8)
                                            anchors.rightMargin: Style.space(8)
                                            spacing: Style.space(2)

                                            Text {
                                                width: parent.width
                                                text: (root.messageOutgoing(modelData) ? "YOU" : (root.groupCall ? "GROUP" : "THEM")) + (root.messageTime(modelData) === "" ? "" : " · " + root.messageTime(modelData))
                                                color: Qt.darker(root.foreground, 1.35)
                                                font.family: root.fontFamily
                                                font.pixelSize: Style.font.caption
                                                font.bold: true
                                            }

                                            Text {
                                                width: parent.width
                                                text: root.messageText(modelData)
                                                color: root.foreground
                                                font.family: root.fontFamily
                                                font.pixelSize: Style.font.body
                                                wrapMode: Text.Wrap
                                            }

                                        }

                                    }

                                }

                            }

                        }

                        Column {
                            visible: String(root.phoneStatus.onion || "") !== "" && root.advancedOpen && !root.relaying
                            width: parent.width
                            spacing: Style.space(6)

                            PanelSeparator {
                                foreground: root.foreground
                            }

                            PanelSectionHeader {
                                text: "MY CALLING ADDRESS"
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                            }

                            Row {
                                width: parent.width
                                spacing: Style.space(8)

                                Column {
                                    width: parent.width - (copyButton.visible ? copyButton.width + parent.spacing : 0)
                                    spacing: Style.space(1)

                                    Text {
                                        width: parent.width
                                        text: root.shortAddress(root.phoneStatus.onion)
                                        color: root.foreground
                                        font.family: root.fontFamily
                                        font.pixelSize: Style.font.body
                                        font.bold: true
                                        elide: Text.ElideMiddle
                                    }

                                    Text {
                                        width: parent.width
                                        text: root.groupPeer ? "A room key is active. Add your phone again before copying a contact card." : "Keep contact cards private — each one includes your call key."
                                        color: root.groupPeer ? root.urgent : Qt.darker(root.foreground, 1.5)
                                        font.family: root.fontFamily
                                        font.pixelSize: Style.font.caption
                                        wrapMode: Text.WordWrap
                                    }

                                }

                                Button {
                                    id: copyButton

                                    visible: !root.groupPeer
                                    text: root.clipboardBusy ? "Copying…" : "Copy contact card"
                                    iconText: "󰆏"
                                    bordered: true
                                    enabled: !root.commandBusy && !root.clipboardBusy
                                    foreground: root.foreground
                                    accent: root.accent
                                    fontFamily: root.fontFamily
                                    hasCursor: root.actionHasCursor("copy")
                                    onHovered: function(hovered) {
                                        root.handleHelpHover("copy", hovered);
                                    }
                                    onClicked: root.copyInvite()
                                    Accessible.role: Accessible.Button
                                    Accessible.name: "Copy my private contact card"
                                    Accessible.description: "Copies this phone's private contact card, including its address and call key"
                                    Accessible.onPressAction: root.copyInvite()

                                    PanelToolTip {
                                        visible: root.helpVisible("copy")
                                        text: "Includes your private calling address and shared call key."
                                        panelForeground: root.foreground
                                        fontFamily: root.fontFamily
                                    }

                                }

                            }

                        }

                        Button {
                            id: advancedButton

                            visible: !root.inSession
                            width: parent.width
                            text: root.advancedOpen ? "Back to phone" : "Advanced"
                            iconText: root.advancedOpen ? "󰁍" : "󰅀"
                            leftAlign: true
                            foreground: root.foreground
                            accent: root.accent
                            fontFamily: root.fontFamily
                            hasCursor: root.actionHasCursor("advanced")
                            onHovered: function(hovered) {
                                root.handleHelpHover("advanced", hovered);
                            }
                            onClicked: root.toggleAdvanced()
                            Accessible.role: Accessible.Button
                            Accessible.name: text
                            Accessible.description: root.advancedOpen ? "Return to your phone" : "Audio, connection, privacy, and troubleshooting settings"
                            Accessible.onPressAction: root.toggleAdvanced()

                            PanelToolTip {
                                visible: root.helpVisible("advanced")
                                text: root.advancedOpen ? "Return to your phone." : "Audio, connection, privacy, and troubleshooting settings."
                                panelForeground: root.foreground
                                fontFamily: root.fontFamily
                            }

                        }

                        Column {
                            id: advancedColumn

                            visible: root.advancedOpen && !root.inSession
                            width: parent.width
                            spacing: Style.space(10)

                            PanelSeparator {
                                foreground: root.foreground
                            }

                            PanelSectionHeader {
                                text: "MANUAL CALL"
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                            }

                            Text {
                                width: parent.width
                                text: "For TerminalPhone troubleshooting only. Paste the other phone's full .onion address; both phones must already share the same call key."
                                color: Qt.darker(root.foreground, 1.35)
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                wrapMode: Text.WordWrap
                            }

                            Row {
                                width: parent.width
                                spacing: Style.space(7)

                                TextField {
                                    id: dialField

                                    width: parent.width - callButton.width - parent.spacing
                                    placeholderText: "Paste 56-character .onion address"
                                    foreground: root.foreground
                                    accent: root.accent
                                    enabled: !root.commandBusy
                                    onAccepted: root.callAddress()
                                    Keys.onPressed: function(event) {
                                        root.handleEditorKeys(event);
                                    }
                                }

                                Button {
                                    id: callButton

                                    text: "Call address"
                                    iconText: "󰏲"
                                    bordered: true
                                    enabled: !root.commandBusy && String(dialField.text || "").trim() !== ""
                                    foreground: root.foreground
                                    accent: root.accent
                                    fontFamily: root.fontFamily
                                    hasCursor: root.actionHasCursor("call")
                                    onHovered: function(hovered) {
                                        if (hovered)
                                            root.selectAction("call");

                                    }
                                    onClicked: root.callAddress()
                                    Accessible.role: Accessible.Button
                                    Accessible.name: "Call this Tor address"
                                    Accessible.onPressAction: root.callAddress()
                                }

                            }

                            PanelSeparator {
                                foreground: root.foreground
                            }

                            PanelSectionHeader {
                                text: "CALL SETTINGS"
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                            }

                            Row {
                                width: parent.width
                                spacing: Style.space(7)

                                Dropdown {
                                    id: qualityDropdown

                                    width: (parent.width - parent.spacing) / 2
                                    label: "VOICE QUALITY"
                                    value: "balanced"
                                    options: [{
                                        "value": "low",
                                        "label": "Low"
                                    }, {
                                        "value": "balanced",
                                        "label": "Balanced"
                                    }, {
                                        "value": "high",
                                        "label": "High"
                                    }]
                                    foreground: root.foreground
                                    accent: root.accent
                                    fontFamily: root.fontFamily
                                    enabled: !root.commandBusy && !root.inSession
                                    hasCursor: root.actionHasCursor("quality")
                                    onHovered: function(hovered) {
                                        root.handleHelpHover("quality", hovered);
                                    }
                                    onChanged: function(value) {
                                        root.setConfig("quality", value);
                                    }
                                    Accessible.role: Accessible.ComboBox
                                    Accessible.name: "Call quality, " + currentLabel()
                                    Accessible.description: "Low saves data; Balanced is recommended; High needs a steadier Tor connection"
                                    Accessible.focusable: true
                                    Accessible.onPressAction: open()

                                    PanelToolTip {
                                        visible: root.helpVisible("quality") && !qualityDropdown.popupOpen
                                        text: "Low saves data; High needs a steadier Tor connection."
                                        panelForeground: root.foreground
                                        fontFamily: root.fontFamily
                                    }

                                }

                                Dropdown {
                                    id: chimeDropdown

                                    width: (parent.width - parent.spacing) / 2
                                    label: "TALK SOUND"
                                    value: "tone"
                                    options: [{
                                        "value": "off",
                                        "label": "Off"
                                    }, {
                                        "value": "tone",
                                        "label": "Tone"
                                    }, {
                                        "value": "double",
                                        "label": "Double"
                                    }, {
                                        "value": "chirp",
                                        "label": "Chirp"
                                    }, {
                                        "value": "ding",
                                        "label": "Ding"
                                    }, {
                                        "value": "click",
                                        "label": "Click"
                                    }]
                                    foreground: root.foreground
                                    accent: root.accent
                                    fontFamily: root.fontFamily
                                    enabled: !root.commandBusy && !root.inSession
                                    hasCursor: root.actionHasCursor("chime")
                                    onHovered: function(hovered) {
                                        root.handleHelpHover("chime", hovered);
                                    }
                                    onChanged: function(value) {
                                        root.setConfig("chime", value);
                                    }
                                    Accessible.role: Accessible.ComboBox
                                    Accessible.name: "Talk sound, " + currentLabel()
                                    Accessible.description: "Plays when the other person starts recording; Off also silences call-status sounds"
                                    Accessible.focusable: true
                                    Accessible.onPressAction: open()

                                    PanelToolTip {
                                        visible: root.helpVisible("chime") && !chimeDropdown.popupOpen
                                        text: "Plays when they talk. Off also silences call cues."
                                        panelForeground: root.foreground
                                        fontFamily: root.fontFamily
                                    }

                                }

                            }

                            Dropdown {
                                id: voiceDropdown

                                width: parent.width
                                label: "VOICE STYLE"
                                value: "none"
                                options: [{
                                    "value": "none",
                                    "label": "None"
                                }, {
                                    "value": "deep",
                                    "label": "Deep"
                                }, {
                                    "value": "high",
                                    "label": "High"
                                }, {
                                    "value": "robot",
                                    "label": "Robot"
                                }, {
                                    "value": "echo",
                                    "label": "Echo"
                                }, {
                                    "value": "whisper",
                                    "label": "Whisper"
                                }]
                                foreground: root.foreground
                                accent: root.accent
                                fontFamily: root.fontFamily
                                enabled: !root.commandBusy && !root.inSession
                                hasCursor: root.actionHasCursor("voice")
                                onHovered: function(hovered) {
                                    root.handleHelpHover("voice", hovered);
                                }
                                onChanged: function(value) {
                                    root.setConfig("voiceEffect", value);
                                }
                                Accessible.role: Accessible.ComboBox
                                Accessible.name: "Voice style, " + currentLabel()
                                Accessible.description: "Changes the clips you send; effects are for fun, not reliable voice disguises"
                                Accessible.focusable: true
                                Accessible.onPressAction: open()

                                PanelToolTip {
                                    visible: root.helpVisible("voice") && !voiceDropdown.popupOpen
                                    text: "Changes sent clips; not a reliable voice disguise."
                                    panelForeground: root.foreground
                                    fontFamily: root.fontFamily
                                }

                            }

                            Toggle {
                                id: snowflakeToggle

                                width: parent.width
                                label: "Snowflake connection"
                                description: root.snowflakeEnabled && !root.snowflakeAvailable ? "Its optional client is missing. Turn this off to use normal Tor." : (root.snowflakeAvailable ? "Helps Tor connect through temporary volunteer proxies when this network blocks Tor. Leave it off unless normal calls fail." : "Helps Tor connect through temporary volunteer proxies when this network blocks Tor. Its optional package is not installed.")
                                checked: root.settingBool("snowflake", false)
                                enabled: !root.commandBusy && !root.inSession && (root.snowflakeAvailable || root.snowflakeEnabled)
                                foreground: root.foreground
                                accent: root.accent
                                fontFamily: root.fontFamily
                                hasCursor: root.actionHasCursor("snowflake")
                                onHovered: function(hovered) {
                                    root.handleHelpHover("snowflake", hovered);
                                }
                                onClicked: root.toggleSnowflake()
                                Accessible.role: Accessible.CheckBox
                                Accessible.name: label
                                Accessible.description: description + " It changes how Tor connects; it is not an extra privacy mode."
                                Accessible.checked: checked
                                Accessible.focusable: enabled
                                Accessible.onPressAction: root.toggleSnowflake()

                                PanelToolTip {
                                    visible: root.helpVisible("snowflake") || snowflakeToggle.activeFocus
                                    text: "Tor via volunteer proxies for blocked networks, not an extra privacy mode."
                                    panelForeground: root.foreground
                                    fontFamily: root.fontFamily
                                }

                            }

                            Toggle {
                                id: hmacToggle

                                width: parent.width
                                label: "Message verification"
                                description: "Checks that voice and text came from someone with this call's private key. Keep this on; both phones must match."
                                checked: root.settingBool("hmac", true)
                                enabled: !root.commandBusy && !root.inSession
                                foreground: root.foreground
                                accent: root.accent
                                fontFamily: root.fontFamily
                                hasCursor: root.actionHasCursor("hmac")
                                onHovered: function(hovered) {
                                    if (hovered)
                                        root.selectAction("hmac");

                                }
                                onClicked: root.toggleConfig("hmac", checked)
                                Accessible.role: Accessible.CheckBox
                                Accessible.name: label
                                Accessible.description: description
                                Accessible.checked: checked
                                Accessible.focusable: true
                                Accessible.onPressAction: root.toggleConfig("hmac", checked)
                            }

                            Button {
                                id: audioButton

                                width: parent.width
                                text: "Audio test"
                                iconText: "󰋋"
                                leftAlign: true
                                bordered: true
                                enabled: !root.commandBusy && !root.inSession
                                foreground: root.foreground
                                accent: root.accent
                                fontFamily: root.fontFamily
                                hasCursor: root.actionHasCursor("audio")
                                onHovered: function(hovered) {
                                    root.handleHelpHover("audio", hovered);
                                }
                                onClicked: root.runAudioTest()
                                Accessible.role: Accessible.Button
                                Accessible.name: "Run audio test"
                                Accessible.description: "Records 3 seconds, then plays it back to test your microphone and speakers"
                                Accessible.onPressAction: root.runAudioTest()

                                PanelToolTip {
                                    visible: root.helpVisible("audio")
                                    text: "Records 3 seconds, then plays it back through your speakers."
                                    panelForeground: root.foreground
                                    fontFamily: root.fontFamily
                                }

                            }

                            Button {
                                id: advancedClearPeerButton

                                visible: root.hasPeer
                                width: parent.width
                                text: root.groupPeer ? "Clear saved room invite" : "Clear paired phone"
                                iconText: "󰆴"
                                leftAlign: true
                                bordered: true
                                enabled: !root.commandBusy
                                foreground: root.urgent
                                accent: root.urgent
                                fontFamily: root.fontFamily
                                hasCursor: root.actionHasCursor("clear-peer")
                                onHovered: function(hovered) {
                                    if (hovered)
                                        root.selectAction("clear-peer");

                                }
                                onClicked: root.clearPeer()
                                Accessible.role: Accessible.Button
                                Accessible.name: text
                                Accessible.description: root.groupPeer ? "Remove the saved room address and call key from this phone" : "Remove the one saved phone from this computer"
                                Accessible.onPressAction: root.clearPeer()
                            }

                            Button {
                                id: clearChatButton

                                visible: root.visibleMessages.length > 0
                                width: parent.width
                                text: "Clear local chat history"
                                iconText: "󰆴"
                                leftAlign: true
                                bordered: true
                                enabled: !root.commandBusy
                                foreground: root.urgent
                                accent: root.urgent
                                fontFamily: root.fontFamily
                                hasCursor: root.actionHasCursor("clear-chat")
                                onHovered: function(hovered) {
                                    if (hovered)
                                        root.selectAction("clear-chat");

                                }
                                onClicked: root.clearChat()
                                Accessible.role: Accessible.Button
                                Accessible.name: "Clear local chat history"
                                Accessible.description: "Delete the bounded plaintext chat history stored on this device"
                                Accessible.onPressAction: root.clearChat()
                            }

                            Button {
                                id: rotateButton

                                visible: !root.rotateConfirm
                                width: parent.width
                                text: "Change my calling address"
                                iconText: "󰑓"
                                leftAlign: true
                                bordered: true
                                enabled: !root.commandBusy && !root.online && !root.inSession
                                foreground: root.urgent
                                accent: root.urgent
                                fontFamily: root.fontFamily
                                hasCursor: root.actionHasCursor("rotate")
                                onHovered: function(hovered) {
                                    root.handleHelpHover("rotate", hovered);
                                }
                                onClicked: root.rotateConfirm = true
                                Accessible.role: Accessible.Button
                                Accessible.name: "Change my calling address"
                                Accessible.description: root.online ? "Go offline first; changing the address makes existing contact cards stop working" : "Creates a new private address; old contact cards stop working"
                                Accessible.onPressAction: root.rotateConfirm = true

                                PanelToolTip {
                                    visible: root.helpVisible("rotate")
                                    text: "Creates a new private address; old contact cards stop working."
                                    panelForeground: root.foreground
                                    fontFamily: root.fontFamily
                                }

                            }

                            Text {
                                visible: root.online && !root.rotateConfirm
                                width: parent.width
                                text: "Go offline before changing your calling address."
                                color: Qt.darker(root.foreground, 1.35)
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                wrapMode: Text.WordWrap
                            }

                            CursorSurface {
                                visible: root.rotateConfirm
                                width: parent.width
                                implicitHeight: rotateColumn.implicitHeight + Style.space(18)
                                current: true
                                foreground: root.urgent
                                accent: root.urgent

                                Column {
                                    id: rotateColumn

                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.leftMargin: Style.space(9)
                                    anchors.rightMargin: Style.space(9)
                                    spacing: Style.space(7)

                                    Text {
                                        width: parent.width
                                        text: "Change your calling address? Existing invites will stop reaching this phone. This cannot be undone."
                                        color: root.foreground
                                        font.family: root.fontFamily
                                        font.pixelSize: Style.font.bodySmall
                                        wrapMode: Text.WordWrap
                                    }

                                    Row {
                                        width: parent.width
                                        spacing: Style.space(7)

                                        Button {
                                            id: rotateCancelButton

                                            width: (parent.width - parent.spacing) / 2
                                            text: "Cancel"
                                            bordered: true
                                            foreground: root.foreground
                                            accent: root.accent
                                            fontFamily: root.fontFamily
                                            hasCursor: root.actionHasCursor("rotate-cancel")
                                            onHovered: function(hovered) {
                                                if (hovered)
                                                    root.selectAction("rotate-cancel");

                                            }
                                            onClicked: root.rotateConfirm = false
                                            Accessible.role: Accessible.Button
                                            Accessible.name: "Cancel address change"
                                            Accessible.onPressAction: root.rotateConfirm = false
                                        }

                                        Button {
                                            id: rotateNowButton

                                            width: (parent.width - parent.spacing) / 2
                                            text: "Change address"
                                            bordered: true
                                            enabled: !root.commandBusy && !root.online
                                            foreground: root.urgent
                                            accent: root.urgent
                                            fontFamily: root.fontFamily
                                            hasCursor: root.actionHasCursor("rotate-now")
                                            onHovered: function(hovered) {
                                                if (hovered)
                                                    root.selectAction("rotate-now");

                                            }
                                            onClicked: root.rotateIdentity()
                                            Accessible.role: Accessible.Button
                                            Accessible.name: "Confirm calling address change"
                                            Accessible.onPressAction: root.rotateIdentity()
                                        }

                                    }

                                }

                            }

                        }

                    }

                    Item {
                        width: parent.width
                        height: Style.space(4)
                    }

                }

                ScrollBar.vertical: ScrollBar {
                    policy: panelFlick.contentHeight > panelFlick.height ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
                }

            }

        }

    }

}
