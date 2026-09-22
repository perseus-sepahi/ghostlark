package com.sepahi.ghostlark.bg

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.nekohasekai.libbox.InterfaceUpdateListener
import java.net.NetworkInterface

/** Tracks the underlying (non-VPN) default network and reports it to the core. */
object DefaultNetworkMonitor {
    @Volatile var defaultNetwork: Network? = null
    private var listener: InterfaceUpdateListener? = null
    private lateinit var connectivity: ConnectivityManager
    private var registered = false

    private val request = NetworkRequest.Builder()
        .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
        .build()

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) { defaultNetwork = network; notifyListener(network) }
        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) { if (network == defaultNetwork) notifyListener(network) }
        override fun onLost(network: Network) { if (network == defaultNetwork) { defaultNetwork = null; notifyListener(null) } }
    }

    fun start(context: Context) {
        connectivity = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        if (registered) return
        val handler = Handler(Looper.getMainLooper())
        if (Build.VERSION.SDK_INT >= 31) connectivity.registerBestMatchingNetworkCallback(request, callback, handler)
        else connectivity.requestNetwork(request, callback, handler)
        registered = true
        defaultNetwork = connectivity.activeNetwork
    }

    fun stop() {
        if (!registered) return
        runCatching { connectivity.unregisterNetworkCallback(callback) }
        registered = false
        defaultNetwork = null
    }

    fun setListener(l: InterfaceUpdateListener?) { listener = l; notifyListener(defaultNetwork) }

    private fun notifyListener(network: Network?) {
        val l = listener ?: return
        if (network == null) { l.updateDefaultInterface("", -1, false, false); return }
        repeat(10) {
            val lp = connectivity.getLinkProperties(network)
            val name = lp?.interfaceName
            if (name != null) {
                val index = runCatching { NetworkInterface.getByName(name)?.index }.getOrNull()
                if (index != null) { l.updateDefaultInterface(name, index, false, false); return }
            }
            Thread.sleep(100)
        }
    }
}
