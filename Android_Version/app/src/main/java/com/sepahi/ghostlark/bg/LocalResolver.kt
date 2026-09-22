package com.sepahi.ghostlark.bg

import android.net.DnsResolver
import android.os.Build
import android.os.CancellationSignal
import android.system.ErrnoException
import io.nekohasekai.libbox.ExchangeContext
import io.nekohasekai.libbox.LocalDNSTransport
import java.net.InetAddress
import java.net.UnknownHostException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors

/** Resolves "local" DNS on the underlying network so system DNS never loops through the tunnel. */
object LocalResolver : LocalDNSTransport {
    private val executor = Executors.newCachedThreadPool()

    override fun raw(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

    override fun exchange(ctx: ExchangeContext, message: ByteArray) {
        val network = DefaultNetworkMonitor.defaultNetwork ?: error("missing default interface")
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) error("raw queries need Android 10")
        val latch = CountDownLatch(1)
        var failure: Throwable? = null
        val signal = CancellationSignal()
        ctx.onCancel { signal.cancel(); latch.countDown() }
        DnsResolver.getInstance().rawQuery(network, message, DnsResolver.FLAG_NO_RETRY, executor, signal,
            object : DnsResolver.Callback<ByteArray> {
                override fun onAnswer(answer: ByteArray, rcode: Int) { if (rcode == 0) ctx.rawSuccess(answer) else ctx.errorCode(rcode); latch.countDown() }
                override fun onError(error: DnsResolver.DnsException) {
                    val cause = error.cause
                    if (cause is ErrnoException) ctx.errnoCode(cause.errno) else failure = error
                    latch.countDown()
                }
            })
        latch.await()
        failure?.let { throw it }
    }

    override fun lookup(ctx: ExchangeContext, network: String, domain: String) {
        val net = DefaultNetworkMonitor.defaultNetwork ?: error("missing default interface")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val latch = CountDownLatch(1)
            var failure: Throwable? = null
            val signal = CancellationSignal()
            ctx.onCancel { signal.cancel(); latch.countDown() }
            val cb = object : DnsResolver.Callback<Collection<InetAddress>> {
                override fun onAnswer(answer: Collection<InetAddress>, rcode: Int) {
                    if (rcode == 0) ctx.success(answer.mapNotNull { it.hostAddress }.joinToString("\n")) else ctx.errorCode(rcode)
                    latch.countDown()
                }
                override fun onError(error: DnsResolver.DnsException) {
                    val cause = error.cause
                    if (cause is ErrnoException) ctx.errnoCode(cause.errno) else failure = error
                    latch.countDown()
                }
            }
            val type = when { network.endsWith("4") -> DnsResolver.TYPE_A; network.endsWith("6") -> DnsResolver.TYPE_AAAA; else -> null }
            if (type != null) DnsResolver.getInstance().query(net, domain, type, DnsResolver.FLAG_NO_RETRY, executor, signal, cb)
            else DnsResolver.getInstance().query(net, domain, DnsResolver.FLAG_NO_RETRY, executor, signal, cb)
            latch.await()
            failure?.let { throw it }
        } else {
            val answer = try { net.getAllByName(domain) } catch (e: UnknownHostException) { ctx.errorCode(3); return }
            ctx.success(answer.mapNotNull { it.hostAddress }.joinToString("\n"))
        }
    }
}
