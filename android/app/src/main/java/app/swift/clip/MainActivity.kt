package app.swift.clip

import android.Manifest
import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.text.InputType
import android.graphics.Color
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.app.AlertDialog
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import com.google.android.material.bottomnavigation.BottomNavigationView
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.PopupMenu
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast

class MainActivity : Activity() {
    private val handler = Handler(Looper.getMainLooper())
    private lateinit var tabs: BottomNavigationView
    private lateinit var pairSection: View
    private lateinit var accessButton: Button
    private lateinit var accessHelp: TextView
    private lateinit var backgroundButton: Button
    private lateinit var backgroundHelp: TextView
    private var showPairing = false
    private var looking = false
    /** The link the code on screen holds. The code is redrawn only when it changes. */
    private var shownLink: String? = null

    /** Wi-Fi can drop or change while the screen is open. The code follows it. */
    private val watchNetwork = object : Runnable {
        override fun run() {
            if (PhotoWeb.link(this@MainActivity) != shownLink) refreshPhoto()
            handler.postDelayed(this, 2_000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        installSplashScreen()
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        tabs = findViewById(R.id.tabs)
        pairSection = findViewById(R.id.pair_section)
        // Android 15 draws the app under the status bar. The title starts below it,
        // and the tabs keep clear of the gesture bar themselves.
        findViewById<View>(R.id.root).setOnApplyWindowInsetsListener { _, insets ->
            @Suppress("DEPRECATION")
            findViewById<View>(R.id.scroll).setPadding(0, insets.systemWindowInsetTop, 0, 0)
            insets
        }
        tabs.setOnItemSelectedListener { item ->
            showTab(item.itemId)
            true
        }
        val saved = getSharedPreferences("swift-clip", MODE_PRIVATE).getString("tab", "mac")
        tabs.selectedItemId = if (saved == "iphone") R.id.tab_iphone else R.id.tab_mac
        showTab(tabs.selectedItemId)
        findViewById<View>(R.id.phone_card).setOnClickListener { editPhoneName() }
        findViewById<View>(R.id.received_card).setOnClickListener { openReceived() }
        accessButton = findViewById(R.id.access)
        accessHelp = findViewById(R.id.access_help)
        backgroundButton = findViewById(R.id.background)
        backgroundHelp = findViewById(R.id.background_help)

        findViewById<Button>(R.id.pair_link).setOnClickListener { askForLink() }
        findViewById<Button>(R.id.pair_cancel).setOnClickListener {
            showPairing = false
            refresh()
        }
        findViewById<Button>(R.id.find).setOnClickListener { findMacs(announce = true) }
        findViewById<View>(R.id.add_phone).setOnClickListener { showAddPhone() }
        findViewById<View>(R.id.menu).setOnClickListener { showMenu(it) }
        ClipSync.onRemoved = { refresh() }
        accessButton.setOnClickListener { openClipboardAccess() }
        backgroundButton.setOnClickListener { openBackgroundSettings() }
        findViewById<Button>(R.id.photo_new).setOnClickListener {
            PhotoWeb.newLink()
            shownLink = null
            refreshPhoto()
            show("New link. Scan the code again.")
        }
        findViewById<Button>(R.id.photo_send).setOnClickListener { pickPhotos() }
        findViewById<Button>(R.id.crash_report).setOnClickListener { copyCrashReport() }
        if (Build.VERSION.SDK_INT >= 33) {
            val needed = listOf(
                Manifest.permission.POST_NOTIFICATIONS,
                Manifest.permission.NEARBY_WIFI_DEVICES,
            ).filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
            if (needed.isNotEmpty()) requestPermissions(needed.toTypedArray(), 1)
        }
        consumeLink(intent)
        // A rotation re-creates the screen with the same intent. Add the photos once.
        if (savedInstanceState == null) consumeShare(intent)
        refresh()
    }

    override fun onPause() {
        ClipSync.screenOpen = false
        ClipSync.onMacState = null
        handler.removeCallbacks(watchNetwork)
        super.onPause()
    }

    override fun onResume() {
        super.onResume()
        ClipSync.screenOpen = true
        ClipSync.onMacState = { updateChrome() }
        refresh()
        handler.removeCallbacks(watchNetwork)
        handler.postDelayed(watchNetwork, 2_000)
        // Android connects the clipboard service a moment after the app opens.
        handler.postDelayed({
            if (!isFinishing && accessibilityOn() && !ClipboardAccessibilityService.running) updateChrome()
        }, 3_500)
        PhotoWeb.start(this)
        ClipForegroundService.start(this)
        ClipSync.onRemoved = {
            showPairing = false
            show("Removed on the Mac")
            refresh()
        }
        ClipSync.startWatch(this)
        if (!ClipSync.isPaired(this) || showPairing) findMacs(announce = false)
        if (ClipSync.isPaired(this)) {
            if (accessibilityOn()) {
                ClipSync.sendCurrent(this) { message ->
                    if (message.startsWith("Sent") || message.startsWith("The Mac")) show(message)
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        consumeLink(intent)
        consumeShare(intent)
    }

    /** Photos or videos shared to SWIFT from another app go to the iPhone page. */
    private fun consumeShare(intent: Intent?) {
        val uris = sharedUris(intent ?: return)
        if (uris.isEmpty()) return
        val label = if (uris.size == 1) "1 item" else "${uris.size} items"
        show("Adding $label for the iPhone…")
        PhotoWeb.add(this, uris) { message ->
            show(message)
            refreshPhoto()
            showIphoneCard()
        }
        showIphoneCard()
    }

    private fun sharedUris(intent: Intent): List<Uri> {
        val found = LinkedHashSet<Uri>()
        when (intent.action) {
            Intent.ACTION_SEND -> {
                val one = if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_STREAM)
                }
                one?.let { found.add(it) }
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                val many = if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
                }
                many?.let { found.addAll(it) }
            }
            else -> return emptyList()
        }
        intent.clipData?.let { clip ->
            for (index in 0 until clip.itemCount) clip.getItemAt(index).uri?.let { found.add(it) }
        }
        return found.toList()
    }

    private fun showIphoneCard() {
        tabs.selectedItemId = R.id.tab_iphone
        refreshPhoto()
    }

    private fun showTab(id: Int) {
        val iphone = id == R.id.tab_iphone
        findViewById<View>(R.id.page_mac).visibility = if (iphone) View.GONE else View.VISIBLE
        findViewById<View>(R.id.page_iphone).visibility = if (iphone) View.VISIBLE else View.GONE
        findViewById<android.widget.ScrollView>(R.id.scroll).scrollTo(0, 0)
        getSharedPreferences("swift-clip", MODE_PRIVATE).edit()
            .putString("tab", if (iphone) "iphone" else "mac").apply()
    }

    /** Photos sent from the iPhone are saved to Pictures/SWIFT, which every gallery shows. */
    private fun openReceived() {
        val choices = listOf(
            Intent.makeMainSelectorActivity(Intent.ACTION_MAIN, Intent.CATEGORY_APP_GALLERY),
            Intent(Intent.ACTION_VIEW, android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI),
        )
        for (intent in choices) {
            try {
                startActivity(intent)
                return
            } catch (_: Exception) {
            }
        }
        show("Open your gallery. Photos from the iPhone are in the SWIFT album.")
    }

    /** Things used now and then, kept off the main screen. */
    private fun showMenu(anchor: View) {
        val paired = ClipSync.isPaired(this)
        val popup = PopupMenu(this, anchor)
        popup.menu.add(0, 1, 0, "Phone name…")
        if (paired && !showPairing) popup.menu.add(0, 2, 1, "Pair a different Mac")
        if (paired) popup.menu.add(0, 3, 2, "Remove this Mac")
        if (CrashLog.read(this) != null) popup.menu.add(0, 4, 3, "Copy crash report")
        popup.setOnMenuItemClickListener { item ->
            when (item.itemId) {
                1 -> editPhoneName()
                2 -> {
                    showPairing = true
                    refresh()
                    findMacs(announce = true)
                }
                3 -> confirmRemoveMac()
                4 -> copyCrashReport()
            }
            true
        }
        popup.show()
    }

    private fun dialogField(field: EditText): View {
        val pad = (22 * resources.displayMetrics.density).toInt()
        return FrameLayout(this).apply {
            setPadding(pad, pad / 3, pad, 0)
            addView(field)
        }
    }

    private fun editPhoneName() {
        val field = EditText(this).apply {
            setText(ClipSync.deviceLabel(this@MainActivity))
            setSelection(text.length)
            hint = "Phone name"
            inputType = InputType.TYPE_CLASS_TEXT
            isSingleLine = true
        }
        AlertDialog.Builder(this)
            .setTitle("Phone name")
            .setMessage("This is the name your Mac sees. A model name does not replace it.")
            .setView(dialogField(field))
            .setPositiveButton("Save") { _, _ -> savePhoneName(field.text.toString()) }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun askForLink() {
        val field = EditText(this).apply {
            hint = "Pairing link or 8 digits"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
            isSingleLine = true
        }
        AlertDialog.Builder(this)
            .setTitle("Pair with a link")
            .setMessage("Paste the pairing link from SWIFT on the Mac, or type its 8 digits.")
            .setView(dialogField(field))
            .setPositiveButton("Pair") { _, _ -> confirmLink(field.text.toString()) }
            .setNegativeButton("Cancel", null)
            .show()
    }

    /** Room for two and a half Macs. More scroll inside the card, not the screen. */
    private fun fitMacList() {
        val scroll = findViewById<View>(R.id.macs_scroll)
        val count = findViewById<LinearLayout>(R.id.macs).childCount
        val row = 64 * resources.displayMetrics.density
        scroll.layoutParams = scroll.layoutParams.apply {
            height = if (count > 2) (row * 2.5f).toInt() else ViewGroup.LayoutParams.WRAP_CONTENT
        }
    }

    private fun copyCrashReport() {
        val report = CrashLog.read(this) ?: return
        getSystemService(android.content.ClipboardManager::class.java)
            ?.setPrimaryClip(android.content.ClipData.newPlainText("SWIFT crash report", report))
        CrashLog.clear(this)
        show("Crash report copied. Paste it into a message or a GitHub issue.")
    }

    private fun consumeLink(intent: Intent?) {
        val data = intent?.data ?: return
        if (data.scheme != "swift") return
        confirmLink(data.toString())
    }

    /**
     * A link can come from anywhere: a web page, a chat, a QR code. Pairing sends
     * this phone's copies to that Mac, so the person says yes to it first.
     */
    private fun confirmLink(raw: String) {
        // Only the 8 digits: look for the Mac on this Wi-Fi and pair with the one that matches.
        ClipSync.extractCode(raw)?.let { code ->
            show("Looking for your Mac…")
            ClipSync.pairWithCodeOnWifi(this, code) {
                show(it)
                if (ClipSync.isPaired(this)) showPairing = false
            }
            return
        }
        val target = ClipSync.describeLink(raw)
        if (target == null) {
            show("Paste the pairing link from SWIFT on the Mac, or type its 8 digits.")
            return
        }
        AlertDialog.Builder(this)
            .setTitle("Pair with ${target.name}?")
            .setMessage("What you copy on this phone will be sent to this Mac at ${target.host}. Pair only with your own Mac.")
            .setPositiveButton("Pair") { _, _ ->
                ClipSync.pairWithLink(this, raw) {
                    show(it)
                    if (ClipSync.isPaired(this)) showPairing = false
                }
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    /** A small code. A phone that scans it hands over its real device name. */
    private fun showAddPhone() {
        val density = resources.displayMetrics.density
        val pad = (20 * density).toInt()
        val status = TextView(this).apply {
            text = "Scan with the other phone's camera. Its real name comes here."
            gravity = Gravity.CENTER
            setPadding(0, pad / 2, 0, 0)
        }
        val adder = AddPhone(this) { name ->
            ClipSync.rememberAddedPhone(this, name)
            status.text = "Added $name"
        }
        val image = ImageView(this).apply { setImageBitmap(adder.qr()) }
        val size = (150 * density).toInt()
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(pad, pad, pad, 0)
            addView(image, LinearLayout.LayoutParams(size, size))
            addView(status)
        }
        adder.start()
        AlertDialog.Builder(this)
            .setTitle("Add phone")
            .setView(box)
            .setPositiveButton("Close", null)
            .setOnDismissListener { adder.stop() }
            .show()
    }

    private fun findMacs(announce: Boolean) {
        if (looking) return
        looking = true
        val macs = findViewById<LinearLayout>(R.id.macs)
        val hint = findViewById<TextView>(R.id.mac_hint)
        macs.removeAllViews()
        fitMacList()
        hint.text = "Looking for your Mac…"
        hint.visibility = View.VISIBLE
        ClipSync.discover(this, found = { mac ->
            macs.addView(macRow(mac))
            fitMacList()
            hint.text = "Tap your Mac."
        }, finished = {
            looking = false
            if (macs.childCount == 0) {
                hint.text = ClipSync.NO_MAC_MESSAGE
                if (announce) show(ClipSync.NO_MAC_MESSAGE)
            } else {
                hint.text = "Tap your Mac."
            }
        })
    }

    private fun macRow(mac: ClipSync.Mac): Button {
        val button = Button(this)
        button.text = mac.name
        button.isAllCaps = false
        button.textSize = 17f
        button.setTextColor(getColor(R.color.ink))
        button.gravity = Gravity.START or Gravity.CENTER_VERTICAL
        button.background = getDrawable(R.drawable.bg_secondary)
        button.backgroundTintList = null
        button.stateListAnimator = null
        val pad = (18 * resources.displayMetrics.density).toInt()
        button.setPadding(pad, 0, pad, 0)
        val params = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            (56 * resources.displayMetrics.density).toInt(),
        )
        params.topMargin = (8 * resources.displayMetrics.density).toInt()
        button.layoutParams = params
        button.setOnClickListener {
            show("Pairing with ${mac.name}…")
            ClipSync.pairOnWifi(this, mac) {
                show(it)
                if (ClipSync.isPaired(this)) showPairing = false
            }
        }
        return button
    }

    private fun show(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_LONG).show()
        if (ClipSync.isPaired(this)) {
            keepAlive()
            // Just paired: start asking the Mac whether it is there.
            ClipSync.startWatch(this)
        }
        updateChrome()
    }

    private fun refresh() {
        updateChrome()
        refreshPhoto()
        if (ClipSync.isPaired(this)) keepAlive()
    }

    private fun refreshPhoto() {
        PhotoWeb.start(this)
        val link = PhotoWeb.link(this)
        val ready = PhotoWeb.count()
        val online = link.isNotEmpty()
        findViewById<View>(R.id.photo_qr_box).visibility = if (online) View.VISIBLE else View.GONE
        findViewById<View>(R.id.photo_offline).visibility = if (online) View.GONE else View.VISIBLE
        findViewById<View>(R.id.photo_address).visibility = if (online) View.VISIBLE else View.GONE
        findViewById<TextView>(R.id.photo_count).apply {
            text = if (ready > 0) "$ready ${if (ready == 1) "item" else "items"} ready" else "Nothing to send yet"
            visibility = if (online || ready > 0) View.VISIBLE else View.GONE
        }
        findViewById<TextView>(R.id.photo_status).text = when {
            !online -> "The iPhone opens a page in Safari. Nothing to install."
            ready > 0 -> "Scan with the iPhone camera. Safari opens with them."
            else -> "Pick photos, then scan with the iPhone camera."
        }
        findViewById<TextView>(R.id.photo_address).text = link
        if (link != shownLink) {
            shownLink = link
            findViewById<ImageView>(R.id.photo_qr).setImageBitmap(if (online) PhotoWeb.qr(this) else null)
        }
    }

    private fun pickPhotos() {
        if (PhotoWeb.link(this).isEmpty()) {
            show("Connect this phone to the same Wi-Fi as the iPhone first.")
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("image/*", "video/*"))
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }
        startActivityForResult(intent, 7)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 7 || resultCode != RESULT_OK || data == null) return
        val uris = mutableListOf<Uri>()
        val clip = data.clipData
        if (clip != null) {
            for (index in 0 until clip.itemCount) uris.add(clip.getItemAt(index).uri)
        } else {
            data.data?.let { uris.add(it) }
        }
        show("Adding ${uris.size} photo${if (uris.size == 1) "" else "s"} for the iPhone…")
        PhotoWeb.add(this, uris) {
            show(it)
            refreshPhoto()
        }
    }

    private fun updateChrome() {
        val paired = ClipSync.isPaired(this)
        val access = accessibilityOn()
        val showForm = !paired || showPairing
        // Switched on in Settings, but Android is not running it: what a crash leaves behind.
        val processAge = android.os.SystemClock.elapsedRealtime() - android.os.Process.getStartElapsedRealtime()
        val stopped = access && !ClipboardAccessibilityService.running && processAge > 3_000
        val staleAccess = stopped || (access && !getSharedPreferences("swift-clip", MODE_PRIVATE)
            .getBoolean("canReadScreen", true))
        val keepsRunning = getSystemService(PowerManager::class.java)?.isIgnoringBatteryOptimizations(packageName) == true
        val needAccess = !access || staleAccess
        findViewById<View>(R.id.crash_report).visibility =
            if (CrashLog.read(this) != null) View.VISIBLE else View.GONE

        findViewById<TextView>(R.id.phone_label).text = ClipSync.deviceLabel(this)

        // Paired is not the same as connected: the Mac may be asleep or on another Wi-Fi.
        val macName = findViewById<TextView>(R.id.mac_name)
        val macState = findViewById<TextView>(R.id.mac_state)
        val macDot = findViewById<ImageView>(R.id.mac_dot)
        if (!paired) {
            macName.text = "No Mac yet"
            macState.text = "Same Wi-Fi as this phone, then Find Mac."
            macDot.visibility = View.GONE
        } else {
            macName.text = ClipSync.pairedName(this)
            macDot.visibility = View.VISIBLE
            val (text, color) = when (ClipSync.macState) {
                ClipSync.MacState.NEARBY -> "Connected" to R.color.ok
                ClipSync.MacState.AWAY -> "Not on this Wi-Fi" to R.color.away
                ClipSync.MacState.CHECKING -> "Checking…" to R.color.away
            }
            macState.text = text
            macDot.imageTintList = android.content.res.ColorStateList.valueOf(getColor(color))
        }
        pairSection.visibility = if (showForm) View.VISIBLE else View.GONE
        findViewById<View>(R.id.pair_cancel).visibility = if (paired && showPairing) View.VISIBLE else View.GONE

        findViewById<View>(R.id.access_row).visibility = if (needAccess) View.VISIBLE else View.GONE
        findViewById<View>(R.id.background_row).visibility = if (keepsRunning) View.GONE else View.VISIBLE
        findViewById<TextView>(R.id.clip_title).text = when {
            stopped -> "Clipboard stopped"
            needAccess -> "Clipboard is off"
            else -> "Clipboard is on"
        }
        findViewById<TextView>(R.id.clip_line).text = when {
            stopped -> "Tap Turn on again, switch SWIFT off, then on."
            staleAccess -> "Switch clipboard access off, then on again, once."
            needAccess -> "Turn it on to paste this phone’s copies on the Mac."
            !paired -> "Pair a Mac, then copy here and press ⌘V there."
            else -> "Copy here, then press ⌘V on the Mac."
        }
        accessHelp.text = if (staleAccess) "Clipboard access needs a restart" else "Clipboard access"
        accessButton.text = if (staleAccess) "Turn on again" else "Turn on"
        val opened = backgroundOpened()
        backgroundHelp.text = if (opened) "Set SWIFT to Unrestricted" else "Keep SWIFT running"
        backgroundButton.text = if (opened) "Open" else "Allow"
    }

    private fun savePhoneName(raw: String) {
        ClipSync.saveDeviceName(this, raw)
        Presence.readvertise(this)
        show("This phone is ${ClipSync.deviceLabel(this)}")
    }

    private fun confirmRemoveMac() {
        val name = ClipSync.pairedName(this)
        AlertDialog.Builder(this)
            .setTitle("Remove $name?")
            .setMessage("Copies on this phone will stop going to $name. You can pair again later.")
            .setNegativeButton("Cancel", null)
            .setPositiveButton("Remove") { _, _ ->
                ClipSync.leave(this) {
                    showPairing = false
                    show("Removed $name")
                    refresh()
                }
            }
            .show()
    }

    private fun keepAlive() {
        ClipForegroundService.start(this)
    }

    private fun accessibilityOn(): Boolean {
        val enabled = Settings.Secure.getString(contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES)
            ?: return false
        val name = ComponentName(this, ClipboardAccessibilityService::class.java).flattenToString()
        return enabled.split(':').any { it.equals(name, ignoreCase = true) }
    }

    private fun backgroundOpened(): Boolean {
        return getSharedPreferences("swift-clip", Context.MODE_PRIVATE)
            .getBoolean("backgroundOpened", false)
    }

    private fun openClipboardAccess() {
        if (accessibilityOn() && ClipboardAccessibilityService.running) {
            show("Clipboard access is already on. Copy on this phone, then press ⌘V on the Mac.")
            return
        }
        val component = ComponentName(this, ClipboardAccessibilityService::class.java).flattenToString()
        val details = Intent("android.settings.ACCESSIBILITY_DETAILS_SETTINGS").apply {
            putExtra(Intent.EXTRA_COMPONENT_NAME, component)
            putExtra(":settings:fragment_args_key", component)
        }
        try {
            startActivity(details)
        } catch (_: Exception) {
            startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
            Toast.makeText(
                this,
                "Open Downloaded apps, tap SWIFT, and switch it on.",
                Toast.LENGTH_LONG
            ).show()
        }
    }

    private fun openBackgroundSettings() {
        getSharedPreferences("swift-clip", Context.MODE_PRIVATE).edit()
            .putBoolean("backgroundOpened", true)
            .apply()
        val power = getSystemService(PowerManager::class.java)
        if (power != null && !power.isIgnoringBatteryOptimizations(packageName)) {
            try {
                startActivity(
                    Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                        .setData(Uri.parse("package:$packageName"))
                )
                refresh()
                return
            } catch (_: Exception) {
            }
        }
        val candidates = listOf(
            ComponentName("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity"),
            ComponentName("com.samsung.android.lool", "com.samsung.android.sm.battery.ui.BatteryActivity"),
            ComponentName("com.samsung.android.sm", "com.samsung.android.sm.battery.ui.BatteryActivity"),
        )
        for (component in candidates) {
            try {
                startActivity(Intent().setComponent(component))
                refresh()
                return
            } catch (_: Exception) {
            }
        }
        Toast.makeText(this, "Set SWIFT to Unrestricted in the phone’s battery settings.", Toast.LENGTH_LONG).show()
        startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).setData(
            android.net.Uri.parse("package:$packageName")
        ))
        refresh()
    }
}
