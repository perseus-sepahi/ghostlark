package com.sepahi.ghostlark.bg

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.Process
import android.util.Log
import androidx.core.app.NotificationCompat
import com.sepahi.ghostlark.R
import com.sepahi.ghostlark.ui.MainActivity
import io.nekohasekai.libbox.BridgeOptions
import io.nekohasekai.libbox.BridgeSession
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.ConnectionOwner
import io.nekohasekai.libbox.InterfaceUpdateListener
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.LocalDNSTransport
import io.nekohasekai.libbox.NeighborUpdateListener
import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.PlatformUser
import io.nekohasekai.libbox.ShellSession
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.SystemProxyStatus
import io.nekohasekai.libbox.TunOptions
import io.nekohasekai.libbox.WIFIState
import java.net.Inet6Address
import java.net.InetSocketAddress
import java.net.NetworkInterface
import io.nekohasekai.libbox.NetworkInterface as BoxInterface
import io.nekohasekai.libbox.Notification as BoxNotification

/** Foreground service hosting the sing-box core. Implements the libbox 1.14 platform interface. */
class GhostlarkVpnService : VpnService(), PlatformInterface, CommandServerHandler {
    companion object {
        const val ACTION_START = "com.sepahi.ghostlark.START"
        const val ACTION_STOP = "com.sepahi.ghostlark.STOP"
        const val CHANNEL = "ghostlark-vpn"
        const val NOTIFICATION_ID = 1
        private const val TAG = "GhostlarkVpnService"
    }

    private var commandServer: CommandServer? = null
    private var tunFd: ParcelFileDescriptor? = null
    private val connectivity by lazy { getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager }

    class StringArray(private val it: Iterator<String>) : StringIterator {
        override fun len(): Int = 0
        override fun hasNext(): Boolean = it.hasNext()
        override fun next(): String = it.next()
    }

    private class InterfaceArray(private val it: Iterator<BoxInterface>) : NetworkInterfaceIterator {
        override fun hasNext(): Boolean = it.hasNext()
        override fun next(): BoxInterface = it.next()
    }

    // MARK: lifecycle

    override fun onCreate() {
        super.onCreate()
        DefaultNetworkMonitor.start(this)
        try {
            val cs = CommandServer(this, this)
            cs.start()
            commandServer = cs
        } catch (e: Exception) {
            Log.e(TAG, "command server", e)
            CoreManager.log("[core] command server failed: ${e.message}")
        }
        CoreManager.attach(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> { stopSelf(); return START_NOT_STICKY }
            else -> showForeground("Idle")
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        runCatching { commandServer?.closeService() }
        runCatching { commandServer?.close() }
        commandServer = null
        tunFd?.close(); tunFd = null
        DefaultNetworkMonitor.stop()
        CoreManager.detach(this)
        super.onDestroy()
    }

    override fun onRevoke() {
        CoreManager.log("[core] VPN permission revoked by system")
        runCatching { commandServer?.closeService() }
        tunFd?.close(); tunFd = null
        CoreManager.loaded.value = CoreManager.Loaded.NONE
        CoreManager.revoked.value = CoreManager.revoked.value + 1
    }

    fun loadConfig(config: String) {
        val cs = commandServer ?: error("core not running")
        cs.startOrReloadService(config, OverrideOptions())
    }

    fun unloadConfig() {
        commandServer?.closeService()
        tunFd?.close(); tunFd = null
    }

    // MARK: notification

    private fun buildNotification(text: String): Notification {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26 && nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Ghostlark VPN", NotificationManager.IMPORTANCE_LOW))
        }
        val pi = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        return NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_shield).setContentTitle("Ghostlark").setContentText(text)
            .setOngoing(true).setOnlyAlertOnce(true).setContentIntent(pi).build()
    }

    private fun showForeground(text: String) {
        val n = buildNotification(text)
        if (Build.VERSION.SDK_INT >= 34) startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        else startForeground(NOTIFICATION_ID, n)
    }

    fun updateNotification(text: String) {
        (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).notify(NOTIFICATION_ID, buildNotification(text))
    }

    // MARK: CommandServerHandler

    override fun serviceStop() { unloadConfig(); CoreManager.loaded.value = CoreManager.Loaded.NONE }
    override fun serviceReload() {}
    override fun getSystemProxyStatus(): SystemProxyStatus = SystemProxyStatus()
    override fun setSystemProxyEnabled(enabled: Boolean) {}
    override fun triggerNativeCrash() {}
    override fun writeDebugMessage(message: String?) { message?.let { CoreManager.log(it) } }
    override fun connectSSHAgent(): Int = -1

    // MARK: PlatformInterface

    override fun localDNSTransport(): LocalDNSTransport = LocalResolver
    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true
    override fun autoDetectInterfaceControl(fd: Int) { protect(fd) }

    override fun openTun(options: TunOptions): Int {
        if (prepare(this) != null) error("android: missing vpn permission")
        val builder = Builder().setSession("Ghostlark").setMtu(options.mtu)
        if (Build.VERSION.SDK_INT >= 29) builder.setMetered(false)
        val v4 = options.inet4Address
        while (v4.hasNext()) { val a = v4.next(); builder.addAddress(a.address(), a.prefix()) }
        val v6 = options.inet6Address
        while (v6.hasNext()) { val a = v6.next(); builder.addAddress(a.address(), a.prefix()) }
        if (options.autoRoute) {
            if (options.dnsMode.value != Libbox.DNSModeDisabled) {
                val dns = options.dnsServerAddress
                while (dns.hasNext()) builder.addDnsServer(dns.next())
            }
            if (Build.VERSION.SDK_INT >= 33) {
                val r4 = options.inet4RouteAddress
                if (r4.hasNext()) while (r4.hasNext()) { val p = r4.next(); builder.addRoute(p.address(), p.prefix()) }
                else if (options.inet4Address.hasNext()) builder.addRoute("0.0.0.0", 0)
                val r6 = options.inet6RouteAddress
                if (r6.hasNext()) while (r6.hasNext()) { val p = r6.next(); builder.addRoute(p.address(), p.prefix()) }
                else if (options.inet6Address.hasNext()) builder.addRoute("::", 0)
                val x4 = options.inet4RouteExcludeAddress
                while (x4.hasNext()) { val p = x4.next(); builder.excludeRoute(android.net.IpPrefix(java.net.InetAddress.getByName(p.address()), p.prefix())) }
                val x6 = options.inet6RouteExcludeAddress
                while (x6.hasNext()) { val p = x6.next(); builder.excludeRoute(android.net.IpPrefix(java.net.InetAddress.getByName(p.address()), p.prefix())) }
            } else {
                val r4 = options.inet4RouteRange
                while (r4.hasNext()) { val p = r4.next(); builder.addRoute(p.address(), p.prefix()) }
                val r6 = options.inet6RouteRange
                while (r6.hasNext()) { val p = r6.next(); builder.addRoute(p.address(), p.prefix()) }
            }
            val inc = options.includePackage
            while (inc.hasNext()) runCatching { builder.addAllowedApplication(inc.next()) }
            val exc = options.excludePackage
            while (exc.hasNext()) runCatching { builder.addDisallowedApplication(exc.next()) }
        }
        val pfd = builder.establish() ?: error("android: VPN not prepared or revoked")
        tunFd?.close()
        tunFd = pfd
        return pfd.fd
    }

    override fun useProcFS(): Boolean = Build.VERSION.SDK_INT < 29

    override fun findConnectionOwner(ipProtocol: Int, sourceAddress: String, sourcePort: Int, destinationAddress: String, destinationPort: Int): ConnectionOwner {
        if (Build.VERSION.SDK_INT < 29) error("unsupported")
        val uid = connectivity.getConnectionOwnerUid(ipProtocol, InetSocketAddress(sourceAddress, sourcePort), InetSocketAddress(destinationAddress, destinationPort))
        if (uid == Process.INVALID_UID) error("android: connection owner not found")
        val packages = packageManager.getPackagesForUid(uid)?.toList() ?: emptyList()
        return ConnectionOwner().apply { userId = uid; userName = packages.firstOrNull() ?: ""; setAndroidPackageNames(StringArray(packages.iterator())) }
    }

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) { DefaultNetworkMonitor.setListener(listener) }
    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) { DefaultNetworkMonitor.setListener(null) }

    override fun getInterfaces(): NetworkInterfaceIterator {
        val all = NetworkInterface.getNetworkInterfaces()?.toList() ?: emptyList()
        val out = mutableListOf<BoxInterface>()
        for (network in connectivity.allNetworks) {
            val lp = connectivity.getLinkProperties(network) ?: continue
            val caps = connectivity.getNetworkCapabilities(network) ?: continue
            val ni = all.find { it.name == lp.interfaceName } ?: continue
            out += BoxInterface().apply {
                name = lp.interfaceName
                index = ni.index
                mtu = runCatching { ni.mtu }.getOrDefault(1500)
                dnsServer = StringArray(lp.dnsServers.mapNotNull { it.hostAddress }.iterator())
                gateway = StringArray(lp.routes.filter { it.destination.prefixLength == 0 }.mapNotNull { it.gateway?.hostAddress }.iterator())
                type = when {
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> Libbox.InterfaceTypeWIFI
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> Libbox.InterfaceTypeCellular
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> Libbox.InterfaceTypeEthernet
                    else -> Libbox.InterfaceTypeOther
                }
                addresses = StringArray(ni.interfaceAddresses.map { ia ->
                    val host = if (ia.address is Inet6Address) Inet6Address.getByAddress(ia.address.address).hostAddress else ia.address.hostAddress
                    "$host/${ia.networkPrefixLength}"
                }.iterator())
                var f = 0
                if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) f = f or 0x1 or 0x40
                if (ni.isLoopback) f = f or 0x8
                if (ni.isPointToPoint) f = f or 0x10
                if (ni.supportsMulticast()) f = f or 0x1000
                flags = f
                metered = !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
            }
        }
        return InterfaceArray(out.iterator())
    }

    override fun underNetworkExtension(): Boolean = false
    override fun includeAllNetworks(): Boolean = false
    override fun readWIFIState(): WIFIState? = null
    override fun clearDNSCache() {}

    override fun sendNotification(notification: BoxNotification) {
        CoreManager.log("[core] ${notification.title}: ${notification.body}")
    }
    override fun cancelNotification(identifier: String, typeID: Int) {}
    override fun startNeighborMonitor(listener: NeighborUpdateListener) {}
    override fun closeNeighborMonitor(listener: NeighborUpdateListener) {}
    override fun registerMyInterface(name: String) {}
    override fun usePlatformShell(): Boolean = false
    override fun checkPlatformShell() { error("not supported") }
    override fun openShellSession(user: PlatformUser?, command: String?, environ: StringIterator?, term: String?, rows: Int, cols: Int): ShellSession = error("not supported")
    override fun lookupUser(username: String): PlatformUser = error("not supported")
    override fun lookupSFTPServer(): String = error("not supported")
    override fun readSystemSSHHostKey(): String = error("not supported")
    override fun tailscaleHostname(): String = "${Build.MANUFACTURER} ${Build.MODEL}"
    override fun usePlatformBridge(): Boolean = false
    override fun createBridge(options: BridgeOptions?): BridgeSession = error("not supported")
}
