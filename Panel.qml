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
        "online": false,
        "busy": false,
        "onion": "",
        "remoteAddress": "",
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
    property bool advancedOpen: false
    property bool pairOpen: false
    property bool roomConfirmOpen: false
    property bool rotateConfirm: false
    property bool cursorActive: false
    property int actionIndex: 0
    property string actionCursorId: ""
    property string lastSyncedRemoteAddress: ""
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
    readonly property bool ready: configured && backendInstalled && dependenciesReady
    readonly property bool pttHeld: pttPointerHeld || pttKeyboardHeld || pttAccessibleHeld
    readonly property bool actionBusy: phoneService ? phoneService.actionBusy : true
    readonly property bool commandBusy: phoneService ? phoneService.commandBusy : true
    readonly property bool clipboardBusy: phoneService ? phoneService.clipboardBusy : false
    readonly property var missingDependencies: Array.isArray(phoneStatus.missingDependencies) ? phoneStatus.missingDependencies : []
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
            actions.push("advanced", "quality", "chime", "voice", "snowflake", "hmac", "audio");
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
        if (root.connected) {
            actions.push("ptt", "send", "hangup");
        } else if (root.calling) {
            actions.push("hangup");
        } else if (root.relaying) {
            if (root.relayReady && String(root.phoneStatus.onion || "") !== "")
                actions.push("copy");

            actions.push("hangup");
        } else {
            actions.push("online");
            if (root.phase !== "starting") {
                if (root.online)
                    actions.push("call");

                actions.push("pair");
                if (root.roomConfirmOpen)
                    actions.push("room-cancel", "room-start");
                else
                    actions.push("room");
            }
        }
        if (!root.relaying && String(root.phoneStatus.onion || "") !== "")
            actions.push("copy");

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
            return "Connecting over Tor";

        if (phase === "listening")
            return "Ready for incoming calls";

        if (phase === "calling")
            return groupCall ? "Joining group" : "Calling";

        if (phase === "connected")
            return groupCall ? "Group call" : shortAddress(phoneStatus.remoteAddress);

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
            return "Creating a private route";

        if (phase === "listening")
            return "Share an invite or call an address";

        if (phase === "calling")
            return shortAddress(phoneStatus.remoteAddress);

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

            return "Omaphone · connected to " + shortAddress(phoneStatus.remoteAddress);
        }
        if (calling)
            return groupCall ? "Omaphone · joining a group" : "Omaphone · calling";

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

    function pairInvite() {
        var invite = String(pairField.text || "").trim();
        if (phoneService && phoneService.pairInvite(invite)) {
            pairField.text = "";
            pairOpen = false;
            Qt.callLater(function() {
                keyCatcher.forceActiveFocus();
            });
        } else {
            pairField.forceActiveFocus();
        }
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
        pairOpen = !pairOpen;
        if (pairOpen) {
            Qt.callLater(function() {
                pairField.forceActiveFocus();
                root.revealAction("pair");
            });
        } else {
            pairField.text = "";
            keyCatcher.forceActiveFocus();
        }
    }

    function openRoomConfirm() {
        pairField.text = "";
        pairOpen = false;
        roomConfirmOpen = true;
        advancedOpen = false;
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

    function moveAction(delta) {
        if (mainActions.length === 0)
            return ;

        cursorActive = true;
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

        if (action === "online")
            return onlineButton;

        if (action === "call")
            return callButton;

        if (action === "pair")
            return root.pairOpen ? pairButton : pairToggleButton;

        if (action === "room")
            return roomHostButton;

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
        } else if (action === "online") {
            toggleOnline();
        } else if (action === "call") {
            if (String(dialField.text || "").trim() === "")
                dialField.forceActiveFocus();
            else
                callAddress();
        } else if (action === "pair") {
            if (!pairOpen) {
                roomConfirmOpen = false;
                pairOpen = true;
                Qt.callLater(function() {
                    pairField.forceActiveFocus();
                    root.revealAction("pair");
                });
            } else {
                pairInvite();
            }
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
            toggleConfig("snowflake", snowflakeToggle.checked);
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
            close();
            event.accepted = true;
        } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
            switchPanel((event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab ? -1 : 1);
            event.accepted = true;
        }
    }

    function close() {
        releasePtt();
        pairField.text = "";
        pairOpen = false;
        roomConfirmOpen = false;
        rotateConfirm = false;
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
            refresh();
            Qt.callLater(root.syncAdvancedControls);
            Qt.callLater(root.syncDialAddress);
        }
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
            roomConfirmOpen = false;
            rotateConfirm = false;
            panelFlick.contentY = 0;
        }
    }
    onVisibleChanged: {
        if (!visible)
            releasePtt();

    }
    onOpenedChanged: {
        if (opened) {
            cursorActive = false;
            actionIndex = 0;
            actionCursorId = mainActions.length > 0 ? String(mainActions[0]) : "";
            panelFlick.contentY = 0;
            refresh();
        } else {
            releasePtt();
            pairField.text = "";
            pairOpen = false;
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
            onCloseRequested: root.close()
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

                    Column {
                        id: setupColumn

                        visible: !root.ready
                        width: parent.width
                        spacing: Style.space(8)

                        Text {
                            width: parent.width
                            text: "Set up your private phone. Omaphone creates your calling address and installs its checked, pinned phone engine."
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

                        Button {
                            id: onlineButton

                            visible: !root.inSession && !root.advancedOpen
                            width: parent.width
                            text: root.phase === "starting" ? "Going online…" : (root.online ? "Go offline" : "Go online")
                            iconText: root.online ? "󰖪" : "󰖩"
                            bordered: true
                            enabled: !root.commandBusy && root.phase !== "starting"
                            foreground: root.foreground
                            accent: root.accent
                            fontFamily: root.fontFamily
                            hasCursor: root.actionHasCursor("online")
                            onHovered: function(hovered) {
                                if (hovered)
                                    root.selectAction("online");

                            }
                            onClicked: root.toggleOnline()
                            Accessible.role: Accessible.Button
                            Accessible.name: text
                            Accessible.onPressAction: root.toggleOnline()
                        }

                        Column {
                            visible: !root.inSession && root.phase !== "starting" && !root.advancedOpen
                            width: parent.width
                            spacing: Style.space(7)

                            PanelSectionHeader {
                                text: "CALL"
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                            }

                            Row {
                                width: parent.width
                                spacing: Style.space(7)

                                TextField {
                                    id: dialField

                                    width: parent.width - callButton.width - parent.spacing
                                    placeholderText: "Paste their calling address"
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

                                    text: "Call"
                                    iconText: "󰏲"
                                    bordered: true
                                    enabled: root.online && !root.commandBusy && String(dialField.text || "").trim() !== ""
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
                                    Accessible.name: "Call this address"
                                    Accessible.onPressAction: root.callAddress()
                                }

                            }

                            Button {
                                id: pairToggleButton

                                width: parent.width
                                text: root.pairOpen ? "Cancel" : "Use an invite"
                                iconText: root.pairOpen ? "󰅖" : "󰌷"
                                leftAlign: true
                                enabled: !root.commandBusy
                                foreground: root.foreground
                                accent: root.accent
                                fontFamily: root.fontFamily
                                hasCursor: root.actionHasCursor("pair")
                                onHovered: function(hovered) {
                                    if (hovered)
                                        root.selectAction("pair");

                                }
                                onClicked: root.togglePair()
                                Accessible.role: Accessible.Button
                                Accessible.name: text
                                Accessible.description: "Paste a private Omaphone invite code; this replaces your current call key"
                                Accessible.onPressAction: root.togglePair()
                            }

                            Row {
                                visible: root.pairOpen
                                width: parent.width
                                spacing: Style.space(7)

                                TextField {
                                    id: pairField

                                    width: parent.width - pairButton.width - parent.spacing
                                    placeholderText: "Paste invite code"
                                    password: true
                                    foreground: root.foreground
                                    accent: root.accent
                                    enabled: !root.commandBusy
                                    onAccepted: root.pairInvite()
                                    Keys.onPressed: function(event) {
                                        root.handleEditorKeys(event);
                                    }
                                }

                                Button {
                                    id: pairButton

                                    text: "Use invite"
                                    bordered: true
                                    enabled: !root.commandBusy && String(pairField.text || "").trim() !== ""
                                    foreground: root.foreground
                                    accent: root.accent
                                    fontFamily: root.fontFamily
                                    onClicked: root.pairInvite()
                                    Accessible.role: Accessible.Button
                                    Accessible.name: "Use invite code"
                                    Accessible.onPressAction: root.pairInvite()
                                }

                            }

                            CursorSurface {
                                visible: root.pairOpen
                                width: parent.width
                                implicitHeight: inviteWarning.implicitHeight + Style.space(16)
                                current: true
                                foreground: root.urgent
                                accent: root.urgent

                                Text {
                                    id: inviteWarning

                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.leftMargin: Style.space(9)
                                    anchors.rightMargin: Style.space(9)
                                    text: "Omaphone does not save people yet. Using an invite replaces your current call key, so earlier invites may stop working. Keep invite codes private."
                                    color: root.foreground
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                    wrapMode: Text.WordWrap
                                }

                            }

                        }

                        Column {
                            id: roomColumn

                            visible: !root.inSession && root.phase !== "starting" && !root.advancedOpen
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
                                text: "Joining? Choose Use an invite, paste the host's invite, go online, then choose Call. Hosting uses this computer as the relay; no public server or port forwarding."
                                color: Qt.darker(root.foreground, 1.35)
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.bodySmall
                                wrapMode: Text.WordWrap
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
                                text: "Calling " + root.shortAddress(root.phoneStatus.remoteAddress)
                                color: root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.subtitle
                                font.bold: true
                                horizontalAlignment: Text.AlignHCenter
                                elide: Text.ElideMiddle
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
                                text: "On every participant's device: Use an invite → Go online → Call. Share the same invite privately with everyone."
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
                                        text: root.phoneStatus.remoteTalking === true ? "Listen now; reply when they finish" : "Press and hold, then let go"
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
                            visible: String(root.phoneStatus.onion || "") !== "" && !root.advancedOpen && !root.relaying
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
                                    width: parent.width - copyButton.width - parent.spacing
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
                                        text: "Keep invite codes private — each one includes your call key."
                                        color: Qt.darker(root.foreground, 1.5)
                                        font.family: root.fontFamily
                                        font.pixelSize: Style.font.caption
                                        wrapMode: Text.WordWrap
                                    }

                                }

                                Button {
                                    id: copyButton

                                    text: root.clipboardBusy ? "Copying…" : "Copy invite"
                                    iconText: "󰆏"
                                    bordered: true
                                    enabled: !root.commandBusy && !root.clipboardBusy
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
                                    Accessible.name: "Copy my private invite"
                                    Accessible.description: "The invite contains the room key"
                                    Accessible.onPressAction: root.copyInvite()
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
                                if (hovered)
                                    root.selectAction("advanced");

                            }
                            onClicked: root.toggleAdvanced()
                            Accessible.role: Accessible.Button
                            Accessible.name: text
                            Accessible.onPressAction: root.toggleAdvanced()
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
                                    label: "QUALITY"
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
                                        if (hovered)
                                            root.selectAction("quality");

                                    }
                                    onChanged: function(value) {
                                        root.setConfig("quality", value);
                                    }
                                    Accessible.role: Accessible.ComboBox
                                    Accessible.name: "Call quality, " + currentLabel()
                                    Accessible.focusable: true
                                    Accessible.onPressAction: open()
                                }

                                Dropdown {
                                    id: chimeDropdown

                                    width: (parent.width - parent.spacing) / 2
                                    label: "CHIME"
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
                                        if (hovered)
                                            root.selectAction("chime");

                                    }
                                    onChanged: function(value) {
                                        root.setConfig("chime", value);
                                    }
                                    Accessible.role: Accessible.ComboBox
                                    Accessible.name: "Push-to-talk chime, " + currentLabel()
                                    Accessible.focusable: true
                                    Accessible.onPressAction: open()
                                }

                            }

                            Dropdown {
                                id: voiceDropdown

                                width: parent.width
                                label: "VOICE EFFECT"
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
                                    if (hovered)
                                        root.selectAction("voice");

                                }
                                onChanged: function(value) {
                                    root.setConfig("voiceEffect", value);
                                }
                                Accessible.role: Accessible.ComboBox
                                Accessible.name: "Voice effect, " + currentLabel()
                                Accessible.focusable: true
                                Accessible.onPressAction: open()
                            }

                            Toggle {
                                id: snowflakeToggle

                                width: parent.width
                                label: "Help Tor connect"
                                description: "Use Snowflake when Tor is blocked on this network."
                                checked: root.settingBool("snowflake", false)
                                enabled: !root.commandBusy && !root.inSession
                                foreground: root.foreground
                                accent: root.accent
                                fontFamily: root.fontFamily
                                hasCursor: root.actionHasCursor("snowflake")
                                onHovered: function(hovered) {
                                    if (hovered)
                                        root.selectAction("snowflake");

                                }
                                onClicked: root.toggleConfig("snowflake", checked)
                                Accessible.role: Accessible.CheckBox
                                Accessible.name: label
                                Accessible.description: description
                                Accessible.checked: checked
                                Accessible.focusable: true
                                Accessible.onPressAction: root.toggleConfig("snowflake", checked)
                            }

                            Toggle {
                                id: hmacToggle

                                width: parent.width
                                label: "Message verification"
                                description: "Check each message against the shared call key. Recommended."
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
                                    if (hovered)
                                        root.selectAction("audio");

                                }
                                onClicked: root.runAudioTest()
                                Accessible.role: Accessible.Button
                                Accessible.name: "Run audio test"
                                Accessible.onPressAction: root.runAudioTest()
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
                                tooltipText: root.online ? "Go offline before changing your calling address" : ""
                                foreground: root.urgent
                                accent: root.urgent
                                fontFamily: root.fontFamily
                                hasCursor: root.actionHasCursor("rotate")
                                onHovered: function(hovered) {
                                    if (hovered)
                                        root.selectAction("rotate");

                                }
                                onClicked: root.rotateConfirm = true
                                Accessible.role: Accessible.Button
                                Accessible.name: "Change my calling address"
                                Accessible.description: "Existing invites will stop working"
                                Accessible.onPressAction: root.rotateConfirm = true
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
