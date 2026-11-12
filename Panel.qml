import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "omarchy.power"
  ipcTarget: "omarchy.power"
  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for the togglePercentage method below.
  manageIpc: false
  property var batteryInfo: ({})
  property var systemInfo: ({})
  property var profiles: []
  property string activeProfile: ""
  property int profileIndex: 0
  property bool cursorActive: false
  // The bundled controller retains the original Eco plugin's state directory.
  readonly property string ecoCtl: Quickshell.env("HOME") + "/.config/omarchy/plugins/osean.power-center/bin/eco-ctl"
  property bool ecoActive: false
  property bool ecoExpanded: false
  property var ecoSettings: ({})
  // CPU wattage boost. The controller is a root-owned helper installed at
  // /usr/local/bin/osean-cpu-boost and reachable through a NOPASSWD sudoers
  // drop-in; it only ever accepts status/on/ai/off.
  readonly property string cpuBoostCtl: "/usr/local/bin/osean-cpu-boost"
  property bool boostAvailable: false
  property bool boostActive: false
  property string boostLevel: ""
  property string boostRestriction: "unknown"
  readonly property bool canBoost: boostAvailable && !discharging
    && (boostRestriction === "" || boostRestriction === "lap-detected")
  property bool boostBusy: false
  property string queuedMode: ""
  property string requestedMode: ""
  readonly property bool changingMode: modeProc.running || queuedMode !== ""

  function requestMode(mode) {
    if ((mode === "ai" || mode === "boost") && !canBoost) return
    requestedMode = mode
    queuedMode = mode
    ecoProc.running = false
    profilesProc.running = false
    boostStatusProc.running = false
    dispatchMode()
  }

  function dispatchMode() {
    if (modeProc.running || queuedMode === "") return
    var next = queuedMode
    queuedMode = ""
    modeProc.command = [root.ecoCtl, "mode", next]
    modeProc.running = true
  }
  property var themePalette: ({})
  readonly property color ecoColor: themePalette.green || themePalette.color2 || "#a3be8c"
  readonly property color saverColor: themePalette.yellow || themePalette.color3 || "#ebcb8b"
  readonly property color balancedColor: themePalette.blue || themePalette.color4 || Commons.Color.accent
  readonly property color performanceColor: themePalette.red || themePalette.color1 || Commons.Color.urgent

  function loadThemePalette(raw) {
    var palette = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var match = lines[i].match(/^\s*(green|yellow|blue|red|color[1234])\s*=\s*["']?(#[0-9a-fA-F]{6})/)
      if (match) palette[match[1]] = match[2]
    }
    themePalette = palette
  }

  function modeFill(color) {
    return Qt.rgba(color.r, color.g, color.b, 0.25)
  }

  FileView {
    id: themeColorsFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.loadThemePalette(text())
    onLoadFailed: root.loadThemePalette("")
  }
  property string pendingProfile: ""
  readonly property var choices: {
    var result = []
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i] === "power-saver") result.push("eco")
      result.push(profiles[i])
      if (profiles[i] === "performance") { result.push("boost"); result.push("ai") }
    }
    return result
  }
  readonly property bool showPercentage: setting("showPercentage", false) === true

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }
  // With the percentage shown the button paints a text block wider than an
  // icon, so the open-panel mark takes the painted width instead of the
  // icon-sized fraction of the slot the fallback assumes.
  readonly property real openPanelIndicatorWidth: showPercentage && !button.vertical ? button.glyphPaintedWidth : 0
  readonly property bool batteryPresent: {
    var device = UPower.displayDevice
    return !!(device && device.isPresent)
  }

  function upowerStates() {
    return {
      Charging: UPowerDeviceState.Charging,
      Discharging: UPowerDeviceState.Discharging,
      FullyCharged: UPowerDeviceState.FullyCharged,
      PendingCharge: UPowerDeviceState.PendingCharge
    }
  }

  function selectProfileByDelta(delta) {
    profileIndex = Model.selectProfileIndex(profileIndex, delta, choices)
  }

  function activateSelectedProfile() {
    if (profileIndex < 0 || profileIndex >= choices.length) return
    var name = String(choices[profileIndex])
    if (name === "eco") root.toggleEco()
    else if (name === "boost" || name === "ai") {
      var current = root.changingMode ? root.requestedMode : root.boostLevel
      root.requestMode(current === name ? "boost-off" : name)
    }
    else root.chooseProfile(name)
  }

  function toggleEco() {
    requestMode((changingMode ? requestedMode === "eco" : ecoActive) ? "eco-off" : "eco")
  }

  function runEcoToggle(force) {
    if (ecoActionProc.running) return
    ecoActionProc.command = [root.ecoCtl, "toggle", force]
    ecoActionProc.running = true
  }

  // Leaving Eco restores the profile it changed, so apply the profile the
  // user actually asked for afterwards. setProfile() is already guarded.
  function chooseProfile(profile) {
    if (profile) requestMode(String(profile))
  }

  function updateEcoState(raw) {
    if (changingMode) return
    try {
      var state = JSON.parse(raw)
      root.ecoActive = state.active === true
      root.ecoSettings = state
    } catch (e) {}
  }

  function updateBoostState(raw) {
    if (changingMode) return
    try {
      var state = JSON.parse(raw)
      if (state.error) throw new Error(String(state.error))
      root.boostAvailable = state.available === true
      root.boostActive = state.enhanced === true
      root.boostLevel = String(state.level || (state.enhanced ? "boost" : ""))
      root.boostRestriction = state.degraded === null || state.degraded === undefined ? "unknown" : String(state.degraded)
    } catch (e) {
      root.boostAvailable = false
      root.boostActive = false
      root.boostLevel = ""
      root.boostRestriction = "unknown"
    }
  }

  function setBoost(on) {
    if (on && root.discharging) return
    requestMode(on ? "boost" : "boost-off")
  }

  // The extra wattage only survives on the performance profile. Eco forces
  // power-saver, and any profile switch rewrites the SMU limits, so drop the
  // boost instead of leaving a stale toggle lit.
  function reconcileBoost() {
    if (root.boostActive && (root.ecoActive || root.activeProfile !== "performance")) {
      root.setBoost(false)
    }
  }

  function batteryIcon() {
    var device = UPower.displayDevice
    return Model.batteryIcon(device, root.discharging, upowerStates())
  }

  function modeLabel() {
    var device = UPower.displayDevice
    return Model.modeLabel(device, root.discharging, upowerStates(), Commons.I18n.t)
  }

  function profileIcon(name) {
    return Model.profileIcon(name)
  }

  readonly property bool fullyCharged: {
    var device = UPower.displayDevice
    return device && device.isPresent && device.state === UPowerDeviceState.FullyCharged && !root.chargeThresholdActive
  }
  readonly property bool discharging: {
    var device = UPower.displayDevice
    return !!(device && device.isPresent && UPower.onBattery)
  }
  readonly property bool chargeThresholdActive: {
    var device = UPower.displayDevice
    return Model.chargeThresholdActive(device, root.discharging, upowerStates())
  }
  readonly property bool batteryFull: fullyCharged || (!root.discharging && batteryFraction >= 1)
  readonly property bool batteryFlowIdle: batteryFull || chargeThresholdActive

  // 0..1 charge level, used by the visual progress bar.
  readonly property real batteryFraction: {
    var d = UPower.displayDevice
    return Model.batteryFraction(d)
  }

  readonly property bool charging: {
    var d = UPower.displayDevice
    return d && d.isPresent && !UPower.onBattery && !root.batteryFlowIdle
  }

  readonly property color batteryFillColor: {
    return root.bar ? root.bar.foreground : Commons.Color.foreground
  }

  // Cute agent-flavored phrases shown in the hero status line, rotated on a
  // timer so the panel feels alive when current is flowing (either direction).
  readonly property var chargingPhrases: [
    Commons.I18n.t("power.chargingPhrase1"),
    Commons.I18n.t("power.chargingPhrase2"),
    Commons.I18n.t("power.chargingPhrase3"),
    Commons.I18n.t("power.chargingPhrase4"),
    Commons.I18n.t("power.chargingPhrase5"),
    Commons.I18n.t("power.chargingPhrase6"),
    Commons.I18n.t("power.chargingPhrase7"),
    Commons.I18n.t("power.chargingPhrase8"),
    Commons.I18n.t("power.chargingPhrase9")
  ]
  readonly property var onBatteryPhrases: [
    Commons.I18n.t("power.dischargingPhrase1"),
    Commons.I18n.t("power.dischargingPhrase2"),
    Commons.I18n.t("power.dischargingPhrase3"),
    Commons.I18n.t("power.dischargingPhrase4"),
    Commons.I18n.t("power.dischargingPhrase5"),
    Commons.I18n.t("power.dischargingPhrase6"),
    Commons.I18n.t("power.dischargingPhrase7"),
    Commons.I18n.t("power.dischargingPhrase8"),
    Commons.I18n.t("power.dischargingPhrase9")
  ]
  property int phraseIndex: 0

  // Whichever list is "active" given the current power state.
  readonly property var activePhrases: {
    if (fullyCharged) return []
    if (charging) return chargingPhrases
    if (discharging) return onBatteryPhrases
    return []
  }
  readonly property bool rotatingPhrases: activePhrases.length > 0

  // The battery script's readings in the current language's digits; the
  // time field already comes translated, so it is shown as it arrives.
  function reading(raw) {
    return Model.localizeReading(raw, Commons.I18n.formatNumber)
  }

  readonly property string heroStatusText: {
    if (fullyCharged) return Commons.I18n.t("power.fullyCharged")
    if (rotatingPhrases) return activePhrases[phraseIndex % activePhrases.length]
    return modeLabel()
  }

  function refresh() {
    if (changingMode) return
    if (!batteryPresent) return

    if (!batteryProc.running) batteryProc.running = true
    if (!profilesProc.running) profilesProc.running = true
    if (!systemProc.running) systemProc.running = true
    if (!ecoProc.running) ecoProc.running = true
    if (!boostStatusProc.running) boostStatusProc.running = true
  }

  function updateKeyValue(raw, targetName) {
    var next = Model.parseKeyValue(raw)
    // Keep last known good data if a refresh briefly returns nothing — happens
    // around AC plug/unplug events. Avoids the section collapsing mid-transition.
    if (Object.keys(next).length === 0) return
    if (targetName === "battery") batteryInfo = next
    else systemInfo = next
  }

  function updateProfiles(raw) {
    if (changingMode) return
    var parsed = Model.parseProfiles(raw, profileIndex)
    // Same guard as battery: preserve the last known profile list across
    // transient empty payloads so the buttons don't blink out.
    if (parsed.profiles.length === 0) return
    profiles = parsed.profiles
    activeProfile = parsed.activeProfile
    profileIndex = Math.min(profileIndex, Math.max(0, choices.length - 1))
    if (opened && !cursorActive) {
      var idx = choices.indexOf(ecoActive ? "eco" : activeProfile)
      if (idx >= 0) profileIndex = idx
    }
  }

  function setProfile(profile) {
    if (!profile || actionProc.running) return
    actionProc.command = ["omarchy-powerprofiles-set", root.discharging ? "battery" : "ac", profile]
    actionProc.running = true
  }

  function togglePercentage() {
    root.settings = Object.assign({}, root.settings, { showPercentage: !root.showPercentage })
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  ShellIpc {
    target: "omarchy.power"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function togglePercentage() { root.togglePercentage() }
  }

  onOpenedChanged: {
    if (opened) {
      themeColorsFile.reload()
      if (!batteryPresent) {
        // Deferred: closing here writes the very property whose change
        // is being notified, which QML reports as a binding loop for
        // Panel.opened on every open attempt without a battery.
        Qt.callLater(function() { root.close() })
        return
      }

      refresh()
      if (!boostStatusProc.running) boostStatusProc.running = true
      var idx = choices.indexOf(ecoActive ? "eco" : activeProfile)
      profileIndex = idx >= 0 ? idx : 0
      cursorActive = false
    }
  }

  onBatteryPresentChanged: if (!batteryPresent) close()

  visible: batteryPresent
  implicitWidth: batteryPresent ? button.implicitWidth : 0
  implicitHeight: batteryPresent ? button.implicitHeight : 0

  Process {
    id: batteryProc
    command: ["omarchy-battery-status", "--shell"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateKeyValue(text, "battery") }
  }

  Process {
    id: profilesProc
    command: ["omarchy-powerprofiles-list", "--active-state"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateProfiles(text) }
  }

  Process {
    id: systemProc
    command: ["omarchy-system-stats"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateKeyValue(text, "system") }
  }

  Process {
    id: actionProc
    onExited: root.refresh()
  }

  Process {
    id: ecoProc
    command: [root.ecoCtl, "get"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateEcoState(text) }
  }

  Process {
    id: ecoActionProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateEcoState(text) }
    onExited: function(exitCode) {
      var next = root.pendingProfile
      root.pendingProfile = ""
      if (exitCode === 0 && next !== "") root.setProfile(next)
      else root.refresh()
    }
  }

  Process {
    id: modeProc
    onExited: function(exitCode) {
      if (exitCode !== 0) Quickshell.execDetached(["notify-send", "Power Center", "The power change failed. Check the current mode before retrying."])
      // Process.running may still be true during onExited. Defer both the
      // next queued action and the state refresh until it has settled.
      Qt.callLater(function() {
        if (root.queuedMode !== "") root.dispatchMode()
        else {
          root.requestedMode = ""
          root.refresh()
        }
      })
    }
  }

  Process {
    id: ecoConfigProc
    onExited: root.refresh()
  }

  Process {
    id: boostStatusProc
    command: ["/usr/bin/sudo", "-n", root.cpuBoostCtl, "status"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateBoostState(text) }
    onExited: function(exitCode) {
      // No sudoers entry, no helper, no ryzen_smu: the boost half greys out.
      if (exitCode !== 0) root.boostAvailable = false
    }
  }

  Process {
    id: boostProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateBoostState(text) }
    onExited: {
      root.boostBusy = false
      root.refresh()
    }
  }

  function setEcoConfig(key, value) {
    if (ecoConfigProc.running) return
    ecoConfigProc.command = [root.ecoCtl, "set-config", key, String(value)]
    ecoConfigProc.running = true
  }

  Timer { interval: 5000; running: root.opened; repeat: true; onTriggered: root.refresh() }

  // Rotate the status phrase while the panel is open and we're in a
  // rotating state (charging or on battery). The text swap is wrapped in a
  // fade so the changeover reads as one organism rather than a hard cut.
  Timer {
    id: phraseTimer
    interval: 2800
    running: root.opened && root.rotatingPhrases
    repeat: true
    triggeredOnStart: false
    onTriggered: phraseSwap.restart()
  }

  SequentialAnimation {
    id: phraseSwap
    PropertyAnimation {
      target: panel.loadedContent ? panel.loadedContent.heroStatus : null; property: "opacity"
      to: 0.0; duration: Style.duration(150); easing.type: Easing.OutCubic
    }
    ScriptAction {
      script: {
        var n = root.activePhrases.length
        if (n > 0) root.phraseIndex = (root.phraseIndex + 1) % n
      }
    }
    PropertyAnimation {
      target: panel.loadedContent ? panel.loadedContent.heroStatus : null; property: "opacity"
      to: 1.0; duration: Style.duration(200); easing.type: Easing.OutCubic
    }
  }

  // If we leave a rotating state mid-swap, halt the animation and snap back
  // to full opacity so "FULLY CHARGED" is legible immediately rather than
  // appearing dimmed.
  Connections {
    target: root
    function onRotatingPhrasesChanged() {
      if (!root.rotatingPhrases) {
        phraseSwap.stop()
        if (panel.loadedContent) panel.loadedContent.heroStatus.opacity = 1.0
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.batteryIcon()
    labelText: root.showPercentage && !vertical ? Commons.I18n.formatNumber(Math.round(root.batteryFraction * 100)) + "%" : ""
    slotSize: Style.bar.iconSlot * (root.showPercentage && !vertical ? 2 : 1)
    tooltipText: ""
    onPressed: function(b) {
      if (!root.batteryPresent) return
      if (b === Qt.RightButton) root.togglePercentage()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.batteryPresent
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias heroStatus: heroStatus
      anchors.fill: parent
      implicitHeight: column.implicitHeight
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dx !== 0) root.selectProfileByDelta(dx)
        else if (dy !== 0) root.selectProfileByDelta(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateSelectedProfile()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: battery icon · title/status · percentage ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroPercent.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: root.batteryIcon()
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: Style.duration(200) } }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroPercent.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: Commons.I18n.t("power.battery")
              textFormat: Text.PlainText
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              id: heroStatus
              textFormat: Text.PlainText
              text: root.heroStatusText.toUpperCase()
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Text {
            id: heroPercent
            textFormat: Text.PlainText
            text: root.reading(root.batteryInfo.percentage) || "—"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: Style.duration(200) } }
          }
        }

        // ---------- Battery progress bar ----------
        Item {
          width: parent.width
          implicitHeight: Style.space(8)

          Rectangle {
            id: barTrack
            anchors.fill: parent
            radius: height / 2
            color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)
          }

          Rectangle {
            id: barFill
            anchors.left: barTrack.left
            anchors.verticalCenter: barTrack.verticalCenter
            height: barTrack.height
            radius: barTrack.radius
            color: root.batteryFillColor
            width: Math.max(barTrack.height, barTrack.width * root.batteryFraction)

            Behavior on width { NumberAnimation { duration: Style.duration(320); easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: Style.duration(220) } }

            // Subtle pulse while charging — visible signal that energy is flowing in.
            SequentialAnimation on opacity {
              running: root.charging && !root.fullyCharged && root.opened && !Style.reduceMotion
              loops: Animation.Infinite
              alwaysRunToEnd: true
              NumberAnimation { from: 1.0; to: 0.55; duration: Style.duration(950); easing.type: Easing.InOutSine }
              NumberAnimation { from: 0.55; to: 1.0; duration: Style.duration(950); easing.type: Easing.InOutSine }
            }
          }
        }

        // ---------- Stats ----------
        // Visibility is intentionally only gated by "we've ever loaded data" so
        // the section never collapses mid-transition. fullyCharged is *not* part
        // of the condition: UPower briefly reports FullyCharged on plug-in when
        // the battery sits above the charge-control start threshold, and we
        // refuse to flicker the whole panel for that ~1s window.
        Row {
          visible: root.batteryInfo.percentage !== undefined
          width: parent.width
          spacing: Style.space(20)

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair { label: Commons.I18n.t("power.batterySize"); value: root.reading(root.batteryInfo.size) }
            InfoPair { label: Commons.I18n.t("power.chargeCycles"); value: root.reading(root.batteryInfo.cycles) || "—" }
          }

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair {
              label: root.chargeThresholdActive ? Commons.I18n.t("power.chargeLimit") : (root.discharging ? Commons.I18n.t("power.timeLeft") : Commons.I18n.t("power.timeToFull"))
              value: root.chargeThresholdActive ? (root.reading(root.batteryInfo.threshold) || "-") : (root.batteryFlowIdle ? "-" : (root.batteryInfo.time || "—"))
            }
            InfoPair {
              label: root.chargeThresholdActive ? Commons.I18n.t("power.batteryState") : (root.discharging ? Commons.I18n.t("power.discharging") : Commons.I18n.t("power.charging"))
              value: root.chargeThresholdActive ? Commons.I18n.t("power.holding") : (root.batteryFull ? "-" : root.reading(root.batteryInfo.rate))
            }
          }
        }

        // ---------- Power profile picker ----------
        PanelSeparator {
          foreground: root.bar.foreground
        }

        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: Commons.I18n.t("power.powerProfile")
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Row {
            id: profileRow
            width: parent.width
            spacing: Style.space(6)

            // The power-saver cell splits into Eco + Saver; the performance
            // cell splits into Performance + +W. Both claim extra width for
            // their second half, performance a little more since its labels
            // are longer.
            function halfExtraFor(name) {
              return String(name) === "performance" ? 0.8 : 0.4
            }

            function cellWidthFor(name) {
              var count = root.profiles.length
              if (count <= 0) return 0
              var totalExtra = 0
              if (root.profiles.indexOf("power-saver") >= 0) totalExtra += 0.4
              if (root.profiles.indexOf("performance") >= 0) totalExtra += 0.8
              var unit = (width - spacing * (count - 1)) / (count + totalExtra)
              var label = String(name)
              if (label === "power-saver" || label === "performance") return unit * (1 + halfExtraFor(label))
              return unit
            }

            Repeater {
              model: root.profiles
              Item {
                id: profileCell
                required property var modelData
                required property int index
                readonly property bool isPowerSaver: String(modelData) === "power-saver"
                readonly property bool isPerformance: String(modelData) === "performance"
                readonly property bool hasCursor: root.cursorActive && root.choices[root.profileIndex] === String(modelData)

                width: profileRow.cellWidthFor(modelData)
                height: implicitHeight
                implicitHeight: plainButton.implicitHeight

                Row {
                  id: splitRow
                  anchors.fill: parent
                  spacing: Style.space(2)
                  visible: profileCell.isPowerSaver

                  Button {
                    width: (splitRow.width - splitRow.spacing) / 2
                    height: splitRow.height
                    iconText: "󰌪"
                    iconSize: Style.font.title
                    text: strings.t("profile.eco")
                    fontSize: Style.font.bodySmall
                    foreground: active ? root.ecoColor : root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                    bordered: true
                    active: root.changingMode ? root.requestedMode === "eco" : root.ecoActive
                    color: active ? root.modeFill(root.ecoColor) : (hot ? Style.hoverFillFor(foreground, accent) : "transparent")
                    hasCursor: root.cursorActive && root.choices[root.profileIndex] === "eco"
                    tooltipText: strings.t("profile.eco.tooltip")
                    onClicked: root.toggleEco()
                    onHovered: function(h) {
                      if (h) {
                        root.cursorActive = true
                        root.profileIndex = root.choices.indexOf("eco")
                      }
                    }
                  }

                  Button {
                    width: (splitRow.width - splitRow.spacing) / 2
                    height: splitRow.height
                    iconText: root.profileIcon(String(modelData))
                    iconSize: Style.font.title
                    text: strings.t("profile.saver")
                    fontSize: Style.font.bodySmall
                    foreground: active ? root.saverColor : root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                    bordered: true
                    active: root.activeProfile === modelData && !root.ecoActive
                    color: active ? root.modeFill(root.saverColor) : (hot ? Style.hoverFillFor(foreground, accent) : "transparent")
                    hasCursor: profileCell.hasCursor
                    tooltipText: strings.t("profile.saver.tooltip")
                    onClicked: root.chooseProfile(String(modelData))
                    onHovered: function(h) {
                      if (h) {
                        root.cursorActive = true
                        root.profileIndex = root.choices.indexOf(String(modelData))
                      }
                    }
                  }
                }

                // Performance is split: the left half selects the profile,
                // the right half adds package wattage on top of it. Boosting
                // only makes sense while performance is the active profile.
                Row {
                  id: perfRow
                  anchors.fill: parent
                  spacing: Style.space(2)
                  visible: profileCell.isPerformance

                  Button {
                    width: (perfRow.width - perfRow.spacing) / 2
                    height: perfRow.height
                    iconText: root.profileIcon(String(modelData))
                    iconSize: Style.font.title
                    text: strings.t("profile.perf")
                    fontSize: Style.font.bodySmall
                    foreground: active ? root.performanceColor : root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                    bordered: true
                    active: root.activeProfile === modelData && !root.ecoActive
                    color: active ? root.modeFill(root.performanceColor) : (hot ? Style.hoverFillFor(foreground, accent) : "transparent")
                    hasCursor: profileCell.hasCursor
                    tooltipText: strings.t("profile.perf.tooltip")
                    onClicked: root.chooseProfile(String(modelData))
                    onHovered: function(h) {
                      if (h) {
                        root.cursorActive = true
                        root.profileIndex = root.choices.indexOf(String(modelData))
                      }
                    }
                  }

                  Button {
                    id: boostButton
                    hasCursor: root.cursorActive && root.choices[root.profileIndex] === "boost"
                    onHovered: function(h) {
                      if (h) {
                        root.cursorActive = true
                        root.profileIndex = root.choices.indexOf("boost")
                      }
                    }
                    readonly property bool canBoost: root.boostAvailable
                      && !root.discharging
                      && (root.boostRestriction === "" || root.boostRestriction === "lap-detected")
                    width: (perfRow.width - perfRow.spacing) / 2
                    height: perfRow.height
                    iconText: "󱐋"
                    iconSize: Style.font.title
                    text: strings.t("profile.boost")
                    fontSize: Style.font.bodySmall
                    foreground: active ? root.performanceColor : root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                    bordered: true
                    active: root.changingMode ? root.requestedMode === "boost" : root.boostLevel === "boost"
                    opacity: canBoost ? 1 : 0.4
                    color: active
                      ? root.modeFill(root.performanceColor)
                      : (canBoost && hot ? Style.hoverFillFor(foreground, accent) : "transparent")
                    tooltipText: root.boostRestriction !== "" && root.boostRestriction !== "lap-detected"
                      ? strings.t("profile.boost.restricted")
                      : !canBoost ? strings.t("profile.boost.locked")
                      : (root.boostLevel === "boost" ? strings.t("profile.boost.on") : strings.t("profile.boost.tooltip"))
                    onClicked: {
                      if (canBoost) root.requestMode((root.changingMode ? root.requestedMode === "boost" : root.boostLevel === "boost") ? "boost-off" : "boost")
                    }
                  }
                }

                Button {
                  id: plainButton
                  anchors.fill: parent
                  visible: !profileCell.isPowerSaver && !profileCell.isPerformance
                  iconText: root.profileIcon(String(modelData))
                  iconSize: Style.font.title
                  text: Model.profileLabel(modelData, Commons.I18n.t)
                  fontSize: Style.font.bodySmall
                  foreground: active
                    ? (String(modelData) === "balanced" ? root.balancedColor
                       : String(modelData) === "performance" ? root.performanceColor
                       : root.bar.foreground)
                    : root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  horizontalPadding: Style.spacing.controlPaddingX
                  verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                  bordered: true
                  active: root.activeProfile === modelData
                  color: active
                    ? (String(modelData) === "balanced" ? root.modeFill(root.balancedColor)
                       : String(modelData) === "performance" ? root.modeFill(root.performanceColor)
                       : Style.selectedFillFor(foreground, accent))
                    : (hot ? Style.hoverFillFor(foreground, accent) : "transparent")
                  hasCursor: profileCell.hasCursor
                  onClicked: root.chooseProfile(modelData)
                  onHovered: function(h) {
                    if (h) {
                      root.cursorActive = true
                      root.profileIndex = root.choices.indexOf(String(modelData))
                    }
                  }
                }
              }
            }
          }

          Button {
            width: parent.width
            text: "AI Boost"
            fontFamily: root.bar.fontFamily
            foreground: active ? root.performanceColor : root.bar.foreground
            bordered: true
            active: root.changingMode ? root.requestedMode === "ai" : root.boostLevel === "ai"
            readonly property bool canBoost: root.boostAvailable && !root.discharging
              && (root.boostRestriction === "" || root.boostRestriction === "lap-detected")
            opacity: canBoost ? 1 : 0.4
            color: active ? root.modeFill(root.performanceColor) : (canBoost && hot ? Style.hoverFillFor(foreground, accent) : "transparent")
            tooltipText: "Request 40 W sustained / 42 W burst on AC. May increase heat; firmware can limit performance."
            hasCursor: root.cursorActive && root.choices[root.profileIndex] === "ai"
            onHovered: function(h) { if (h) { root.cursorActive = true; root.profileIndex = root.choices.indexOf("ai") } }
            onClicked: { if (canBoost) root.requestMode(active ? "boost-off" : "ai") }
          }

          Button {
            text: root.changingMode ? strings.t("settings.applying") : strings.t("settings.toggle")
            fontFamily: root.bar.fontFamily
            foreground: root.bar.foreground
            onClicked: root.ecoExpanded = !root.ecoExpanded
          }

          Text {
            width: parent.width
            visible: root.boostRestriction !== "" && root.boostRestriction !== "lap-detected"
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            text: strings.t("profile.boost.restricted")
          }

          Column {
            width: parent.width
            visible: root.ecoExpanded
            spacing: Style.space(4)

            PanelSectionHeader {
              text: strings.t("settings.title")
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Text {
              width: parent.width
              visible: root.ecoActive
              text: strings.t("settings.disableFirst")
              textFormat: Text.PlainText
              color: root.bar.foreground
              opacity: 0.7
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: [
                { key: "auto_switch_battery", state: "auto_switch", label: strings.t("settings.auto") },
                { key: "adjust_blur", state: "adjust_blur", label: strings.t("settings.blur") },
                { key: "adjust_opacity", state: "adjust_opacity", label: strings.t("settings.opacity") },
                { key: "adjust_animations", state: "adjust_animations", label: strings.t("settings.animations") },
                { key: "adjust_powerprofile", state: "adjust_powerprofile", label: strings.t("settings.profile") },
                { key: "adjust_brightness", state: "adjust_brightness", label: strings.t("settings.brightness") }
              ]
              Toggle {
                required property var modelData
                width: parent.width
                implicitHeight: Style.space(40)
                label: modelData.label
                checked: root.ecoSettings[modelData.state] === true
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                enabled: !root.ecoActive && !ecoConfigProc.running
                opacity: enabled ? 1 : 0.5
                onClicked: root.setEcoConfig(modelData.key, !checked)
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(10)
              enabled: !root.ecoActive && root.ecoSettings.adjust_brightness === true && !ecoConfigProc.running
              opacity: enabled ? 1 : 0.5

              Text {
                width: Style.space(145)
                anchors.verticalCenter: parent.verticalCenter
                text: strings.t("settings.target").arg(root.ecoSettings.target_brightness || 35)
                textFormat: Text.PlainText
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              PanelSlider {
                bar: root.bar
                width: parent.width - Style.space(155)
                minimum: 20
                maximum: 70
                step: 5
                integer: true
                value: root.ecoSettings.target_brightness || 35
                onReleased: function(v) { root.setEcoConfig("target_brightness", Math.round(v)) }
              }
            }
          }
        }
      }
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    InfoLabel { text: label }
    Item { width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2); height: 1 }
    InfoValue { text: value }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    opacity: 0.6
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
