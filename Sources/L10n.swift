import Foundation
import Synchronization

/// Languages MyDuoBar ships. `system` follows the macOS language list.
enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case zhHant = "zh-Hant"
    case en
    case ja

    /// Menu title, shown in each language's own name so it stays readable after a wrong pick.
    var menuTitle: String {
        switch self {
        case .system: return L10n.systemDefault
        case .zhHant: return "繁體中文"
        case .en: return "English"
        case .ja: return "日本語"
        }
    }
}

/// All user-facing text. Every phrase takes Traditional Chinese, English and Japanese together,
/// so the compiler rejects a string that is missing a translation.
/// Nonisolated and lock-protected: status readers build strings on a background queue.
enum L10n {
    static let preferenceKey = "appLanguage"
    private static let testOverride = Mutex<AppLanguage?>(nil)
    private static let testSuite = Mutex<String?>(nil)

    /// Tests pin a language without touching the user's defaults.
    static func overrideForTesting(_ language: AppLanguage?) { testOverride.withLock { $0 = language } }
    /// Tests keep the stored preference in a throwaway suite instead of the process's standard defaults.
    static func useDefaultsSuiteForTesting(_ suite: String?) { testSuite.withLock { $0 = suite } }
    private static var defaults: UserDefaults {
        guard let suite = testSuite.withLock({ $0 }), let suiteDefaults = UserDefaults(suiteName: suite) else { return .standard }
        return suiteDefaults
    }

    static var preference: AppLanguage {
        AppLanguage(rawValue: defaults.string(forKey: preferenceKey) ?? "") ?? .system
    }

    /// The concrete language in use; never `.system`.
    static var current: AppLanguage {
        if let pinned = testOverride.withLock({ $0 }), pinned != .system { return pinned }
        let chosen = preference
        if chosen != .system { return chosen }
        // Read the global list: this app's own AppleLanguages override would otherwise shadow it.
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
        for identifier in global ?? Locale.preferredLanguages {
            if identifier.hasPrefix("ja") { return .ja }
            if identifier.hasPrefix("zh") { return .zhHant }
            if identifier.hasPrefix("en") { return .en }
        }
        return .en
    }

    /// Stores the choice. A fixed language also sets this app's AppleLanguages so the system-drawn
    /// permission prompts (InfoPlist.strings) match after the next launch.
    static func setPreference(_ language: AppLanguage) {
        let defaults = self.defaults
        if language == .system {
            defaults.removeObject(forKey: preferenceKey)
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set(language.rawValue, forKey: preferenceKey)
            defaults.set([language.rawValue], forKey: "AppleLanguages")
        }
    }

    private static func pick(_ zhHant: String, _ en: String, _ ja: String) -> String {
        switch current {
        case .ja: return ja
        case .en: return en
        case .zhHant, .system: return zhHant
        }
    }

    // MARK: Language
    static var systemDefault: String { pick("跟隨系統", "System Default", "システムに従う") }
    static var language: String { pick("語言", "Language", "言語") }
    static var languageNote: String {
        pick("系統權限提示的語言會在重新開啟 App 後套用。",
             "System permission prompts switch language after you relaunch the app.",
             "システムの許可ダイアログの言語は、アプリを再起動すると反映されます。")
    }

    // MARK: Lists
    static var listSeparator: String { pick("、", ", ", "、") }
    static var summarySeparator: String { pick("，", ", ", "、") }

    // MARK: Focus
    static var off: String { pick("未開啟", "Off", "オフ") }
    static var on: String { pick("已開啟", "On", "オン") }
    static var notShared: String { pick("狀態未共享", "Not Shared", "共有されていません") }
    static var focusNotSharedYet: String { pick("系統尚未共享專注狀態", "macOS hasn't shared Focus status yet.", "システムが集中モードの状態をまだ共有していません。") }
    static var focusNeedsReading: String { pick("需要讀取系統專注狀態", "Focus status hasn't been read yet.", "集中モードの状態をまだ読み取っていません。") }
    static var focusAllowInSettings: String {
        pick("在 MyDuoBar 設定中允許讀取專注狀態。僅讀取是否專注，不區分具體模式。",
             "Allow Focus access in MyDuoBar Settings. Only whether Focus is on is read, not which mode.",
             "MyDuoBar の設定で集中モードの読み取りを許可してください。オンかどうかだけを読み取り、モードの種類は区別しません。")
    }

    // MARK: Battery
    static var reading: String { pick("讀取中", "Reading…", "読み込み中") }
    static var externalPower: String { pick("外接電源", "External Power", "外部電源") }
    static var noInternalBattery: String { pick("此 Mac 沒有內建電池", "This Mac has no built-in battery", "この Mac には内蔵バッテリーがありません") }
    static var charging: String { pick("正在充電", "Charging", "充電中") }
    static var fullyCharged: String { pick("電量已充滿", "Fully Charged", "充電完了") }
    static var pluggedInNotCharging: String { pick("已接上電源 · 未充電", "Plugged In · Not Charging", "電源接続中 · 充電停止中") }
    static var onBattery: String { pick("電池供電", "On Battery", "バッテリー駆動") }
    static func onBattery(hours: Int, minutes: Int) -> String {
        pick("電池供電 · 約 \(hours) 小時 \(minutes) 分鐘",
             "On Battery · About \(hours) hr \(minutes) min",
             "バッテリー駆動 · 残り約 \(hours) 時間 \(minutes) 分")
    }
    static var battery: String { pick("電池", "Battery", "バッテリー") }
    static func batteryLevel(_ value: String) -> String { pick("電量 \(value)", "Battery \(value)", "バッテリー \(value)") }
    static func chargingToLimit(_ limit: Int) -> String { pick("正在充電到 \(limit)% 上限", "Charging to \(limit)% Limit", "上限 \(limit)% まで充電中") }
    static func chargedToLimit(_ limit: Int) -> String { pick("已充電到 \(limit)% 上限", "Charged to \(limit)% Limit", "上限 \(limit)% まで充電済み") }

    // MARK: Battery submenu
    static var chargeLimit: String { pick("充電上限", "Charge Limit", "充電上限") }
    static func chargeLimitOn(_ limit: Int) -> String { pick("充到 \(limit)% 就停止充電", "Stops charging at \(limit)%", "\(limit)% で充電を停止") }
    static var chargeLimitOff: String { pick("未限制，會充到 100%", "Off · Charges to 100%", "制限なし · 100% まで充電") }
    static var chargeLimitUnsupported: String {
        pick("此 Mac 或此版 macOS 不提供充電上限", "Not available on this Mac or macOS version", "この Mac または macOS では利用できません")
    }
    static func chargeLimitLevel(_ limit: Int) -> String { pick("停在 \(limit)%", "Stop at \(limit)%", "\(limit)% で停止") }
    static var chargeLimitToggle: String { pick("切換充電上限", "Turn the charge limit on or off", "充電上限を切り替え") }
    static var batterySettingsMenu: String { pick("電池設定…", "Battery Settings…", "バッテリー設定…") }

    // MARK: Network
    static var wifiConnected: String { pick("已連線 Wi-Fi", "Connected to Wi-Fi", "Wi-Fi に接続済み") }
    static var ethernet: String { pick("乙太網路", "Ethernet", "Ethernet") }
    static var ethernetConnected: String { pick("乙太網路已連線", "Ethernet Connected", "Ethernet 接続済み") }
    static var noWiFiInterface: String { pick("無 Wi-Fi 介面", "No Wi-Fi Interface", "Wi-Fi インターフェイスなし") }
    static var wifiNotConnected: String { pick("Wi-Fi 未連線", "Wi-Fi Not Connected", "Wi-Fi 未接続") }
    static var wifiOff: String { pick("Wi-Fi 已關閉", "Wi-Fi Off", "Wi-Fi オフ") }
    static var networkNameHidden: String { pick("網路名稱受系統保護 · ", "Network name hidden by macOS · ", "ネットワーク名は macOS により非表示 · ") }
    static var usingWiredNetwork: String { pick("正在使用有線網路", "Using a wired network", "有線ネットワークを使用中") }
    static var noNetworkPath: String { pick("沒有可用網路路徑", "No network path available", "利用可能なネットワーク経路がありません") }
    static var openWiFiSettingsHint: String { pick("開啟 Wi-Fi 設定以管理連線", "Open Wi-Fi Settings to manage connections", "Wi-Fi 設定を開いて接続を管理") }
    static var notConnected: String { pick("未連線", "Not Connected", "未接続") }
    static var turnedOff: String { pick("已關閉", "Off", "オフ") }
    static var connected: String { pick("已連線", "Connected", "接続済み") }
    static var signalStrong: String { pick("訊號很好", "Strong Signal", "電波良好") }
    static var signalFair: String { pick("訊號一般", "Fair Signal", "電波普通") }
    static var signalWeak: String { pick("訊號較弱", "Weak Signal", "電波が弱い") }

    // MARK: VPN
    static var systemProxyOn: String { pick("系統代理已開啟", "System Proxy On", "システムプロキシ オン") }
    static var unavailable: String { pick("狀態不可用", "Unavailable", "取得できません") }
    static var unidentifiedTunnel: String { pick("偵測到未識別的通道", "Unidentified Tunnel Detected", "不明なトンネルを検出") }
    static var unidentifiedTunnelHelp: String {
        pick("偵測到網路通道，但 macOS 未提供可確認的 VPN 名稱，因此不會點亮 VPN 圖示。",
             "A network tunnel was detected, but macOS provided no confirmable VPN name, so the VPN dot stays off.",
             "ネットワークトンネルを検出しましたが、macOS が確認できる VPN 名を提供していないため、VPN のドットは点灯しません。")
    }
    static var personalVPN: String { pick("個人 VPN", "Personal VPN", "個人用 VPN") }

    // MARK: Audio
    static var soundOutputUnavailable: String { pick("聲音輸出不可用", "Sound Output Unavailable", "サウンド出力を利用できません") }
    static var currentOutputDevice: String { pick("目前的輸出裝置", "Current Output Device", "現在の出力装置") }
    static var muted: String { pick("已靜音", "Muted", "消音中") }
    static var notMuted: String { pick("未靜音", "Not Muted", "消音オフ") }
    static var noVolumeInfo: String { pick("裝置不提供音量狀態", "Device doesn't report volume", "デバイスが音量を報告しません") }
    static var sound: String { pick("聲音", "Sound", "サウンド") }

    // MARK: Dots
    static var headphones: String { pick("耳機", "Headphones", "ヘッドフォン") }
    static var mute: String { pick("靜音", "Mute", "消音") }
    static var focus: String { pick("專注", "Focus", "集中モード") }
    static var vpnConnected: String { pick("VPN 已連線", "VPN Connected", "VPN 接続済み") }
    static var headphonesConnected: String { pick("耳機已連線", "Headphones Connected", "ヘッドフォン接続済み") }
    static var focusOn: String { pick("專注已開啟", "Focus On", "集中モード オン") }

    // MARK: Wi-Fi submenu
    static var knownNetworks: String { pick("已知的網路", "Known Networks", "既知のネットワーク") }
    static var otherNetworks: String { pick("其他網路", "Other Networks", "その他のネットワーク") }
    static var wifiSettingsMenu: String { pick("Wi-Fi 設定…", "Wi-Fi Settings…", "Wi-Fi 設定…") }
    static var scanningNetworks: String { pick("正在搜尋網路…", "Scanning for Networks…", "ネットワークを検索中…") }
    static var noNetworksFound: String { pick("找不到網路", "No Networks Found", "ネットワークが見つかりません") }
    static var noKnownNetworksNearby: String { pick("附近沒有已知的網路", "No Known Networks Nearby", "近くに既知のネットワークはありません") }
    static var allowNetworkNames: String { pick("允許顯示網路名稱…", "Allow Network Names…", "ネットワーク名の表示を許可…") }
    static var secured: String { pick("需要密碼", "Secured", "パスワード保護") }
    static var wifiPower: String { pick("Wi-Fi 開關", "Wi-Fi Power", "Wi-Fi のオン/オフ") }

    // MARK: VPN submenu
    static var vpnConnecting: String { pick("連線中…", "Connecting…", "接続中…") }
    static var vpnDisconnecting: String { pick("正在中斷…", "Disconnecting…", "切断中…") }
    static var vpnInvalid: String { pick("設定無效", "Invalid Configuration", "構成が無効です") }
    static var noVPNConfigurations: String { pick("系統中沒有 VPN 設定", "No VPN Configurations", "VPN 構成がありません") }
    static var vpnSettingsMenu: String { pick("VPN 設定…", "VPN Settings…", "VPN 設定…") }
    static var vpnOtherRouteActive: String { pick("偵測到其他 VPN 路由，無法在此切換", "Another VPN route is active; switch it in its own app", "別の VPN ルートが有効です（ここでは切り替えできません）") }
    static var vpnSystemProxyActive: String { pick("系統代理已開啟，無法在此切換", "System proxy is on; change it in its own app", "システムプロキシがオンです（ここでは切り替えできません）") }
    static func vpnToggle(_ name: String) -> String { pick("切換 \(name)", "Toggle \(name)", "\(name) を切り替え") }

    // MARK: Sound submenu
    static var volume: String { pick("音量", "Volume", "音量") }
    static var soundSettingsMenu: String { pick("聲音設定…", "Sound Settings…", "サウンド設定…") }
    static var muteUnsupported: String { pick("此裝置無法靜音", "This device can't be muted", "このデバイスは消音できません") }
    static var volumeUnsupported: String { pick("此裝置無法調整音量", "This device's volume can't be changed", "このデバイスの音量は変更できません") }
    static var muteToggle: String { pick("切換靜音", "Turn mute on or off", "消音を切り替え") }

    static var outputDevices: String { pick("輸出裝置", "Output", "出力装置") }
    static var noOutputDevices: String { pick("沒有可用的輸出裝置", "No Output Devices", "出力装置がありません") }
    static var inputDevices: String { pick("輸入裝置", "Input", "入力装置") }
    static var noInputDevices: String { pick("沒有可用的輸入裝置", "No Input Devices", "入力装置がありません") }

    // MARK: Bluetooth submenu
    static var bluetooth: String { pick("藍牙", "Bluetooth", "Bluetooth") }
    static var bluetoothDevices: String { pick("裝置", "Devices", "デバイス") }
    static var bluetoothOff: String { pick("藍牙已關閉", "Bluetooth Off", "Bluetooth オフ") }
    static var bluetoothUnavailable: String { pick("此 Mac 沒有藍牙", "Bluetooth Unavailable", "Bluetooth を利用できません") }
    static var noPairedDevices: String { pick("沒有已配對的裝置", "No Paired Devices", "ペアリング済みのデバイスがありません") }
    static var bluetoothSettingsMenu: String { pick("藍牙設定…", "Bluetooth Settings…", "Bluetooth 設定…") }
    static func bluetoothToggle(_ name: String) -> String { pick("連線或中斷 \(name)", "Connect or disconnect \(name)", "\(name) を接続または切断") }
    /// AirPods levels, e.g. "左 100% · 右 90% · 盒 86%"; parts the device doesn't report are left out.
    static func earbudsBattery(left: Int?, right: Int?, case box: Int?) -> String {
        var parts: [String] = []
        if let left { parts.append(pick("左 \(left)%", "L \(left)%", "左 \(left)%")) }
        if let right { parts.append(pick("右 \(right)%", "R \(right)%", "右 \(right)%")) }
        if let box { parts.append(pick("盒 \(box)%", "Case \(box)%", "ケース \(box)%")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Icon guide
    static var iconGuide: String { pick("圖示說明", "Icon Guide", "アイコンの見かた") }
    static var guideRing: String {
        pick("外圈：電池電量，電量減少時從右側開始消退。",
             "Outer ring: battery level. It shortens from the right as charge drops.",
             "外周：バッテリー残量。残量が減ると右側から短くなります。")
    }
    static var guideRingGreen: String { pick("綠色外圈：已接上電源。", "Green ring: connected to power.", "緑の外周：電源に接続中。") }
    static var guideRingYellow: String { pick("黃色外圈：低耗電模式已開啟。", "Yellow ring: Low Power Mode is on.", "黄色の外周：低電力モードがオン。") }
    static var guideCenter: String {
        pick("中間：Wi-Fi 訊號強度，斜線代表未連線，使用有線網路時顯示網路圖示。連接耳機時會短暫顯示耳機圖示。",
             "Center: Wi-Fi signal strength. A slash means not connected; a network symbol means a wired connection. Headphones show here briefly when they connect.",
             "中央：Wi-Fi の電波強度。斜線は未接続、ネットワーク記号は有線接続を表します。ヘッドフォンを接続すると、しばらくその記号を表示します。")
    }
    static var guideVolume: String {
        pick("底部：音量，每一點代表 25%，點亮越多音量越大；靜音時變成一條橫線。",
             "Bottom: volume. Each mark is 25%; more lit marks mean louder. While muted, a single bar appears instead.",
             "下部：音量。1 つの点が 25% で、点灯が多いほど大きい音量です。消音中は 1 本の横線になります。")
    }
    static var guideVolumeHidden: String {
        pick("底部：音量目前已隱藏。", "Bottom: volume is hidden.", "下部：音量は非表示です。")
    }

    // MARK: Panel
    static var thisMac: String { pick("此 Mac", "This Mac", "この Mac") }
    static var sampleStatus: String { pick("範例狀態", "Sample", "サンプル") }
    static func open(_ page: String) -> String { pick("開啟\(page)", "Open \(page)", "\(page)を開く") }

    // MARK: System Settings pages
    static var wifiSettings: String { pick("Wi-Fi 設定", "Wi-Fi Settings", "Wi-Fi 設定") }
    static var networkSettings: String { pick("網路設定", "Network Settings", "ネットワーク設定") }
    static var batterySettings: String { pick("電池設定", "Battery Settings", "バッテリー設定") }
    static var vpnSettings: String { pick("VPN 設定", "VPN Settings", "VPN 設定") }
    static var bluetoothSettings: String { pick("藍牙設定", "Bluetooth Settings", "Bluetooth 設定") }
    static var soundSettings: String { pick("聲音設定", "Sound Settings", "サウンド設定") }
    static var focusSettings: String { pick("專注模式設定", "Focus Settings", "集中モード設定") }
    static var menuBarSettings: String { pick("選單列設定", "Menu Bar Settings", "メニューバー設定") }

    // MARK: Menu
    static var hideSystemIcons: String { pick("關閉對應選單列圖示", "Hide Matching Menu Bar Icons…", "対応するメニューバー項目を非表示…") }
    static var settingsMenu: String { pick("設定…", "Settings…", "設定…") }
    static var quit: String { pick("結束 MyDuoBar", "Quit MyDuoBar", "MyDuoBar を終了") }

    // MARK: Settings window
    static var settingsTitle: String { pick("MyDuoBar 設定", "MyDuoBar Settings", "MyDuoBar 設定") }
    static var tagline: String { pick("一個位置，讀懂 Mac 的狀態。", "Your Mac's status, in one place.", "Mac の状態をひと目で。") }
    static var launchAtLogin: String { pick("登入時自動啟動", "Launch at Login", "ログイン時に起動") }
    static var menuBarOnlyNote: String {
        pick("只在選單列顯示。按一下即可查看，按一下其他地方或按 Esc 收起。",
             "Lives only in the menu bar. Click to view; click elsewhere or press Esc to close.",
             "メニューバーにのみ表示されます。クリックで表示し、ほかの場所をクリックするか Esc キーで閉じます。")
    }
    static var positionNote: String {
        pick("位置：按住 ⌘ 拖到控制中心左側。macOS 會記住你調整的位置。",
             "Position: hold ⌘ and drag it to the left of Control Center. macOS remembers where you put it.",
             "位置：⌘ キーを押しながらコントロールセンターの左側へドラッグします。macOS がその位置を記憶します。")
    }
    static var bottomVolume: String { pick("底部音量", "Bottom Volume", "下部の音量") }
    static var bottomVolumeNote: String {
        pick("圖示底部的四點顯示目前輸出裝置的音量，每點 25%；靜音時變成一條橫線。取消勾選可隱藏。",
             "The four marks at the bottom of the icon show the current output's volume, 25% each; while muted they become a single bar. Uncheck to hide them.",
             "アイコン下部の 4 つの点は現在の出力装置の音量を 25% 刻みで示し、消音中は 1 本の横線になります。チェックを外すと非表示になります。")
    }
    static var showVolumeMarks: String { pick("在圖示底部顯示音量", "Show volume at the bottom of the icon", "アイコンの下部に音量を表示") }
    static var tidyMenuBar: String { pick("整理系統選單列", "Tidy the Menu Bar", "メニューバーを整理") }
    static var tidyMenuBarNote: String {
        pick("在系統設定中關閉原生 Wi-Fi、電池的選單列顯示，即可留出空間。",
             "Turn off the built-in Wi-Fi and Battery menu bar items in System Settings to free up space.",
             "システム設定で標準の Wi-Fi とバッテリーのメニューバー表示をオフにすると、スペースを確保できます。")
    }
    static var statusAccess: String { pick("狀態讀取", "Status Access", "状態の読み取り") }
    static var allowFocus: String { pick("允許讀取專注狀態…", "Allow Focus Access…", "集中モードの読み取りを許可…") }
    static var allowWiFiName: String { pick("允許顯示 Wi-Fi 名稱…", "Allow Wi-Fi Name…", "Wi-Fi 名の表示を許可…") }
    static var statusAccessNote: String {
        pick("顯示 Wi-Fi 名稱需要定位服務權限，App 不會取得地理座標。專注狀態未共享時，選單中會標示「狀態未共享」。",
             "Showing the Wi-Fi name requires Location Services permission; the app never reads your coordinates. When Focus status isn't shared, the menu shows “Not Shared”.",
             "Wi-Fi 名の表示には位置情報サービスの許可が必要ですが、座標は取得しません。集中モードの状態が共有されていない場合、メニューに「共有されていません」と表示されます。")
    }
    static func versionFooter(_ version: String) -> String { pick("\(version) · 本機執行", "\(version) · Runs locally", "\(version) · ローカルで動作") }
    static var focusPrompt: String {
        pick("按一下下方按鈕，並在系統對話框中允許讀取。另外還需在系統設定中開啟「共享專注狀態」。",
             "Click the button below and allow access in the system dialog. Also turn on “Share Focus Status” in System Settings.",
             "下のボタンをクリックし、システムのダイアログで許可してください。さらにシステム設定で「集中モードの状態を共有」をオンにしてください。")
    }
    static var focusReadable: String { pick("專注狀態可讀 · ", "Focus status available · ", "集中モードの状態を取得可能 · ") }
    static var loginItemFailed: String { pick("自動啟動尚未完成", "Couldn't Set Launch at Login", "ログイン時の起動を設定できませんでした") }
    static var focusNotSharedTitle: String { pick("專注狀態尚未共享", "Focus Status Not Shared", "集中モードの状態が共有されていません") }
    static var focusNotSharedBody: String {
        pick("請在系統設定中允許 MyDuoBar 讀取專注狀態，並在專注模式 → 專注狀態中開啟共享。MyDuoBar 只讀取是否專注，開啟時點亮圓點。",
             "Allow MyDuoBar to read Focus status in System Settings, and turn on sharing under Focus → Focus Status. MyDuoBar only reads whether Focus is on and lights the dot when it is.",
             "システム設定で MyDuoBar による集中モードの読み取りを許可し、「集中モード → 集中モードの状態」で共有をオンにしてください。MyDuoBar は集中モードがオンかどうかだけを読み取り、オンのときにドットを点灯します。")
    }
    static var openFocusSettings: String { pick("開啟專注設定", "Open Focus Settings", "集中モード設定を開く") }
    static var later: String { pick("稍後", "Later", "後で") }
}
