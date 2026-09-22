package com.sepahi.ghostlark.ui

import android.Manifest
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.List
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.sepahi.ghostlark.bg.CoreManager
import com.sepahi.ghostlark.model.ProxyNode
import com.sepahi.ghostlark.model.Tier
import com.sepahi.ghostlark.model.Transport

class MainActivity : ComponentActivity() {
    private val vm: GhostlarkViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 33) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        setContent {
            MaterialTheme(colorScheme = darkColorScheme(
                primary = Color(0xFF3B9DFA), secondary = Color(0xFF22D3A6), background = Color(0xFF0B1B3A),
                surface = Color(0xFF12254A), surfaceVariant = Color(0xFF1A3160), onBackground = Color.White, onSurface = Color.White,
            )) {
                Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) { AppRoot(vm) }
            }
        }
    }
}

@Composable
fun AppRoot(vm: GhostlarkViewModel) {
    var tab by remember { mutableStateOf(0) }
    val context = androidx.compose.ui.platform.LocalContext.current
    var pending by remember { mutableStateOf<(() -> Unit)?>(null) }
    val vpnLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { r ->
        if (r.resultCode == android.app.Activity.RESULT_OK) pending?.invoke()
        pending = null
    }
    val withVpnPermission: (() -> Unit) -> Unit = { action ->
        val intent = VpnService.prepare(context)
        if (intent == null) action() else { pending = action; vpnLauncher.launch(intent) }
    }

    Scaffold(bottomBar = {
        NavigationBar {
            NavigationBarItem(tab == 0, { tab = 0 }, { Icon(Icons.Default.Home, null) }, label = { Text("Home") })
            NavigationBarItem(tab == 1, { tab = 1 }, { Icon(Icons.Default.List, null) }, label = { Text("Servers") })
            NavigationBarItem(tab == 2, { tab = 2 }, { Icon(Icons.Default.Share, null) }, label = { Text("Sources") })
            NavigationBarItem(tab == 3, { tab = 3 }, { Icon(Icons.Default.Settings, null) }, label = { Text("Settings") })
        }
    }) { pad ->
        Box(Modifier.padding(pad)) {
            when (tab) {
                0 -> DashboardScreen(vm, withVpnPermission)
                1 -> ServersScreen(vm, withVpnPermission)
                2 -> SourcesScreen(vm)
                else -> SettingsScreen(vm)
            }
        }
    }
}

private fun fmtBytes(b: Long): String {
    val u = arrayOf("B", "KB", "MB", "GB"); var v = b.toDouble(); var i = 0
    while (v >= 1024 && i < 3) { v /= 1024; i++ }
    return if (i == 0) "$b B" else "%.1f %s".format(v, u[i])
}

@Composable
fun DashboardScreen(vm: GhostlarkViewModel, withVpn: (() -> Unit) -> Unit) {
    val conn = vm.conn
    val ringColor = when (conn) {
        is ConnState.Connected -> if (conn.shield) Color(0xFF3B9DFA) else Color(0xFF22D3A6)
        is ConnState.Connecting -> Color(0xFFF5A623)
        is ConnState.Failed -> Color(0xFFE5484D)
        else -> Color(0xFF3A5C9A)
    }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Text("Ghostlark", fontSize = 26.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(18.dp))
        Box(Modifier.size(200.dp), contentAlignment = Alignment.Center) {
            Canvas(Modifier.fillMaxSize()) {
                drawArc(ringColor.copy(alpha = 0.2f), 0f, 360f, false, style = Stroke(16.dp.toPx(), cap = StrokeCap.Round))
                if (conn.isConnected) drawArc(ringColor, -90f, 360f, false, style = Stroke(16.dp.toPx(), cap = StrokeCap.Round))
            }
            androidx.compose.foundation.Image(androidx.compose.ui.res.painterResource(com.sepahi.ghostlark.R.mipmap.ic_launcher), "Ghostlark",
                modifier = Modifier.size(132.dp).alpha(if (conn.isConnected) 1f else 0.4f))
        }
        Spacer(Modifier.height(14.dp))
        val headline = vm.phase ?: when (conn) {
            is ConnState.Connected -> listOfNotNull(if (vm.settings.extraStealthOn && !conn.node.isWarp) "Extra Stealth" else null, if (conn.shield) "Shield" else null)
                .let { if (it.isEmpty()) "Protected" else "Protected · " + it.joinToString(" + ") }
            is ConnState.Connecting -> conn.phase
            is ConnState.Failed -> "Not connected"
            else -> if (vm.isFetching) vm.fetchStatus else "Not connected"
        }
        Text(headline, fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
        val sub = when (conn) {
            is ConnState.Connected -> (vm.exitInfo ?: "Verifying exit…") + (if (vm.settings.extraStealthOn && vm.poolSize > 1) " · failover pool of ${vm.poolSize}" else "")
            is ConnState.Failed -> conn.message
            is ConnState.Connecting -> "Nothing is exposed until the tunnel is verified."
            else -> "Traffic is using your normal connection."
        }
        Text(sub, color = Color(0xFFB8C4DC), modifier = Modifier.padding(top = 4.dp, start = 12.dp, end = 12.dp))
        if (vm.isTesting) {
            Spacer(Modifier.height(8.dp))
            LinearProgressIndicator(progress = { vm.testDone.toFloat() / maxOf(1, vm.testTotal) }, modifier = Modifier.fillMaxWidth(0.8f))
            Text("${vm.testDone}/${vm.testTotal} tested · ${vm.testOk} reachable", color = Color(0xFFB8C4DC), fontSize = 12.sp)
        }
        Spacer(Modifier.height(16.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            if (conn.isConnected || conn.isBusy) {
                Button(onClick = { vm.disconnect() }) { Text("Disconnect") }
            } else {
                Button(onClick = { withVpn { vm.autoConnect() } }, enabled = !vm.busy) { Text("Find best & connect") }
                if (vm.isTesting) OutlinedButton(onClick = { vm.cancelTest() }) { Text("Stop") }
                else OutlinedButton(onClick = { vm.quickScan() }, enabled = !vm.busy) { Text("Quick scan") }
            }
        }
        Spacer(Modifier.height(18.dp))
        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(14.dp)) {
                Text("Modes", fontWeight = FontWeight.SemiBold)
                ModeRow("Stealth", "Reality-first, TLS fragmentation, .ir direct, DNS over HTTPS", vm.settings.stealthMode) { v -> vm.updateSettings { it.copy(stealthMode = v) } }
                ModeRow("Extra Stealth", "Reality / verified-TLS only, quiet scan, QUIC blocked, failover pool. Same speed.", vm.settings.extraStealth, enabled = vm.settings.stealthMode) { v -> vm.updateSettings { it.copy(extraStealth = v) } }
                ModeRow("Shield (WARP over proxy)", "Cloudflare WARP inside the proxy: operator sees only ciphertext", vm.settings.shieldMode) { v -> vm.updateSettings { it.copy(shieldMode = v) } }
                ModeRow("Auto-reconnect", "Move to the next verified server if the tunnel drops", vm.settings.autoReconnect) { v -> vm.updateSettings { it.copy(autoReconnect = v) } }
                Text("Changes apply on the next connection.", fontSize = 11.sp, color = Color(0xFF8A99B8))
            }
        }
        Spacer(Modifier.height(12.dp))
        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(14.dp)) {
                Text("Traffic", fontWeight = FontWeight.SemiBold)
                Text("↓ ${fmtBytes(vm.downBps)}/s · ${fmtBytes(vm.totalDown)} total")
                Text("↑ ${fmtBytes(vm.upBps)}/s · ${fmtBytes(vm.totalUp)} total")
                Text("${vm.usableCount} servers · ${vm.verifiedCount} verified", color = Color(0xFF8A99B8), fontSize = 12.sp)
            }
        }
        vm.warning?.let { Spacer(Modifier.height(10.dp)); Text(it, color = Color(0xFFF5A623)) }
        vm.lastError?.let { Spacer(Modifier.height(10.dp)); Text(it, color = Color(0xFFE5484D)) }
        (vm.conn as? ConnState.Connected)?.node?.let { n ->
            Spacer(Modifier.height(12.dp))
            Card(Modifier.fillMaxWidth()) { Column(Modifier.padding(14.dp)) { Text("Current server", fontWeight = FontWeight.SemiBold); NodeRow(n, showSource = true) } }
        }
    }
}

@Composable
fun ModeRow(title: String, help: String, value: Boolean, enabled: Boolean = true, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) { Text(title); Text(help, fontSize = 11.sp, color = Color(0xFF8A99B8)) }
        Switch(checked = value, onCheckedChange = onChange, enabled = enabled)
    }
}

@Composable
fun Badge(text: String, color: Color) {
    Surface(color = color.copy(alpha = 0.18f), shape = MaterialTheme.shapes.small) {
        Text(text, color = color, fontSize = 10.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp))
    }
}

fun tierColor(t: Tier) = when (t) { Tier.STRONG -> Color(0xFF22D3A6); Tier.GOOD -> Color(0xFF3B9DFA); Tier.WEAK -> Color(0xFFF5A623); Tier.UNSAFE -> Color(0xFFE5484D) }

@Composable
fun NodeRow(n: ProxyNode, showSource: Boolean = false) {
    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(n.countryFlag ?: "·", fontSize = 22.sp, modifier = Modifier.width(34.dp))
        Column(Modifier.weight(1f)) {
            Text(n.name, maxLines = 1, overflow = TextOverflow.Ellipsis, fontWeight = FontWeight.Medium)
            val transport = if (n.transport == Transport.TCP) "" else " · ${n.transport.name}"
            Text("${n.proto.label}$transport · ${n.securityBadge}" + (if (showSource) " · ${n.sourceName}" else ""), fontSize = 11.sp, color = Color(0xFF8A99B8), maxLines = 1, overflow = TextOverflow.Ellipsis)
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.padding(top = 3.dp)) {
                Badge(n.tier.label, tierColor(n.tier)); Badge("Stealth ${n.stealthScore}", Color(0xFFB07CFF))
                if (n.extraStealthEligible) Badge("Extra", Color(0xFFE879F9))
                if (n.shieldCapable == true) Badge("Shield", Color(0xFF3B9DFA))
            }
        }
        Column(horizontalAlignment = Alignment.End) {
            val ms = n.latencyMs
            when {
                ms != null -> Text("$ms ms", color = if (ms < 400) Color(0xFF22D3A6) else if (ms < 1200) Color(0xFFF5A623) else Color(0xFFE5484D))
                n.lastError != null -> Text("✕", color = Color(0xFFE5484D))
                else -> Text("—", color = Color(0xFF8A99B8))
            }
        }
    }
}

@Composable
fun ServersScreen(vm: GhostlarkViewModel, withVpn: (() -> Unit) -> Unit) {
    var confirm by remember { mutableStateOf<ProxyNode?>(null) }
    Column(Modifier.fillMaxSize().padding(horizontal = 14.dp)) {
        Spacer(Modifier.height(8.dp))
        OutlinedTextField(vm.filterText, { vm.setFilter(it) }, Modifier.fillMaxWidth(), placeholder = { Text("Name, host, country code, source") }, singleLine = true)
        Row(Modifier.padding(vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            FilterChip(vm.onlyVerified, { vm.showVerifiedOnly(!vm.onlyVerified) }, { Text("Verified only") })
            IconButton(onClick = { vm.refreshSources() }, enabled = !vm.busy) { Icon(Icons.Default.Refresh, "Refresh sources") }
            TextButton(onClick = { vm.quickScan() }, enabled = !vm.busy) { Text("Quick scan") }
            TextButton(onClick = { vm.fullScan() }, enabled = !vm.busy) { Text("Full scan") }
        }
        val status = when {
            vm.isTesting -> "${vm.testDone}/${vm.testTotal} tested · ${vm.testOk} OK"
            vm.isFetching -> vm.fetchStatus
            else -> "${vm.displayed.size} shown · ${vm.usableCount} usable · ${vm.verifiedCount} verified"
        }
        Text(status, fontSize = 12.sp, color = Color(0xFF8A99B8))
        if (vm.isTesting) LinearProgressIndicator(progress = { vm.testDone.toFloat() / maxOf(1, vm.testTotal) }, modifier = Modifier.fillMaxWidth())
        LazyColumn(Modifier.fillMaxSize()) {
            items(vm.displayed.take(2000), key = { it.id }) { n ->
                Box(Modifier.clickable { confirm = n }) { NodeRow(n) }
                HorizontalDivider(color = Color(0x22FFFFFF))
            }
        }
    }
    confirm?.let { n ->
        AlertDialog(onDismissRequest = { confirm = null }, title = { Text(n.name, maxLines = 2) },
            text = { Column { Text("${n.proto.label} · ${n.transport.name} · ${n.securityBadge}\n${n.server}:${n.port}"); n.notes.forEach { Text("• $it", fontSize = 12.sp, color = Color(0xFFB8C4DC)) } } },
            confirmButton = { TextButton(onClick = { confirm = null; withVpn { vm.connect(n) } }) { Text("Connect") } },
            dismissButton = { TextButton(onClick = { confirm = null }) { Text("Cancel") } })
    }
}

@Composable
fun SourcesScreen(vm: GhostlarkViewModel) {
    var url by remember { mutableStateOf("") }
    var links by remember { mutableStateOf("") }
    Column(Modifier.fillMaxSize().padding(14.dp)) {
        Text("Sources", fontSize = 22.sp, fontWeight = FontWeight.Bold)
        Text("Public lists fetched over HTTPS with jsDelivr and Statically mirrors raced in parallel.", fontSize = 12.sp, color = Color(0xFF8A99B8))
        Spacer(Modifier.height(8.dp))
        LazyColumn(Modifier.weight(1f)) {
            items(vm.sources, key = { it.id }) { s ->
                Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                    Switch(s.enabled, { vm.toggleSource(s.id, it) })
                    Column(Modifier.weight(1f).padding(start = 8.dp)) {
                        Text(s.name, fontWeight = FontWeight.Medium)
                        Text(s.url, fontSize = 10.sp, color = Color(0xFF8A99B8), maxLines = 1, overflow = TextOverflow.Ellipsis)
                        s.lastCount?.let { Text("$it links", fontSize = 11.sp, color = Color(0xFF22D3A6)) }
                        s.lastError?.let { Text(it, fontSize = 11.sp, color = Color(0xFFE5484D), maxLines = 1) }
                    }
                    if (!s.isBuiltIn) IconButton(onClick = { vm.removeSource(s.id) }) { Icon(Icons.Default.Delete, "Remove") }
                }
                HorizontalDivider(color = Color(0x22FFFFFF))
            }
        }
        OutlinedTextField(url, { url = it }, Modifier.fillMaxWidth(), placeholder = { Text("Subscription URL (https://…)") }, singleLine = true)
        Row(Modifier.padding(top = 6.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = { vm.addSource("", url); url = "" }, enabled = url.startsWith("http")) { Text("Add") }
            Button(onClick = { vm.refreshSources() }, enabled = !vm.busy) { Text("Fetch all") }
        }
        Spacer(Modifier.height(8.dp))
        OutlinedTextField(links, { links = it }, Modifier.fillMaxWidth(), placeholder = { Text("Paste vless:// vmess:// trojan:// ss:// links to import") }, maxLines = 3)
        TextButton(onClick = { val n = vm.importLinks(links); links = ""; CoreManager.log("[import] $n new servers") }, enabled = links.isNotBlank()) { Text("Import links") }
    }
}

@Composable
fun SettingsScreen(vm: GhostlarkViewModel) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val logs by CoreManager.logs.collectAsState()
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(14.dp)) {
        Text("Settings", fontSize = 22.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(6.dp))
        Text("Stealth", fontWeight = FontWeight.SemiBold, color = Color(0xFF3B9DFA))
        ModeRow("Stealth mode", "", vm.settings.stealthMode) { v -> vm.updateSettings { it.copy(stealthMode = v) } }
        ModeRow("Extra Stealth", "Only Reality or verified-TLS WebSocket/gRPC servers on HTTPS ports; Reality decoys naming big self-hosted sites ranked down; at most ${com.sepahi.ghostlark.model.AppSettings.EXTRA_SCAN_SIZE} quiet probes; QUIC blocked; failover pool of verified servers. Tunnel speed is unchanged.", vm.settings.extraStealth, enabled = vm.settings.stealthMode) { v -> vm.updateSettings { it.copy(extraStealth = v) } }
        ModeRow("Fragment TLS handshakes", "Defeats SNI filters that block the proxy hostname", vm.settings.tlsFragment) { v -> vm.updateSettings { it.copy(tlsFragment = v) } }
        ModeRow("Also fragment Reality", "Off by default: Reality already looks like normal TLS", vm.settings.fragmentReality) { v -> vm.updateSettings { it.copy(fragmentReality = v) } }
        ModeRow("Route .ir sites directly", "", vm.settings.domesticDirect) { v -> vm.updateSettings { it.copy(domesticDirect = v) } }
        Spacer(Modifier.height(10.dp))
        Text("Shield (Cloudflare WARP)", fontWeight = FontWeight.SemiBold, color = Color(0xFF3B9DFA))
        ModeRow("Shield mode: WARP over proxy", "", vm.settings.shieldMode) { v -> vm.updateSettings { it.copy(shieldMode = v) } }
        ModeRow("Fall back to plain proxy if no server relays UDP", "", vm.settings.shieldFallback) { v -> vm.updateSettings { it.copy(shieldFallback = v) } }
        Row(verticalAlignment = Alignment.CenterVertically) {
            val w = vm.warp
            Text(if (w != null) "Device ${w.id.take(8)}… · ${w.v4}" else "No WARP account yet", Modifier.weight(1f), fontSize = 13.sp)
            if (w != null) TextButton(onClick = { vm.resetWarp() }) { Text("Reset") }
            else TextButton(onClick = { vm.ensureWarp() }, enabled = !vm.warpBusy) { Text(if (vm.warpBusy) "Registering…" else "Register") }
        }
        Spacer(Modifier.height(10.dp))
        Text("Protection", fontWeight = FontWeight.SemiBold, color = Color(0xFF3B9DFA))
        ModeRow("Auto-reconnect", "", vm.settings.autoReconnect) { v -> vm.updateSettings { it.copy(autoReconnect = v) } }
        Text("Kill switch: enable \"Always-on VPN\" and \"Block connections without VPN\" for Ghostlark in Android's VPN settings. The system then drops all traffic whenever the tunnel is down.", fontSize = 12.sp, color = Color(0xFFB8C4DC))
        TextButton(onClick = { runCatching { context.startActivity(Intent(Settings.ACTION_VPN_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) } }) { Text("Open Android VPN settings") }
        Spacer(Modifier.height(10.dp))
        Text("Server list", fontWeight = FontWeight.SemiBold, color = Color(0xFF3B9DFA))
        ModeRow("Hide unsafe servers", "Plaintext or broken ciphers", vm.settings.hideUnsafe) { v -> vm.updateSettings { it.copy(hideUnsafe = v) } }
        ModeRow("Include Weak servers when auto-selecting", "", vm.settings.includeWeak) { v -> vm.updateSettings { it.copy(includeWeak = v) } }
        Spacer(Modifier.height(10.dp))
        Text("About", fontWeight = FontWeight.SemiBold, color = Color(0xFF3B9DFA))
        Text("Ghostlark drives the open-source sing-box core (SagerNet, GPLv3). Free public proxies are run by unknown volunteers: assume the operator can see any traffic that is not itself encrypted (HTTPS, or Shield mode). Ghostlark sends no telemetry.", fontSize = 12.sp, color = Color(0xFFB8C4DC))
        Spacer(Modifier.height(10.dp))
        Text("Log (last 40 lines)", fontWeight = FontWeight.SemiBold, color = Color(0xFF3B9DFA))
        logs.takeLast(40).forEach { Text(it, fontSize = 10.sp, color = Color(0xFF8A99B8), maxLines = 2, overflow = TextOverflow.Ellipsis) }
    }
}
