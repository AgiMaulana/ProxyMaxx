package com.proxymaxx.vpn.vpn

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress

class RoutingPolicyTest {

    private val httpOnly = VpnConfig()
    private val everything = VpnConfig(routeHttpOnly = false)
    private val bypassed = VpnConfig(proxyModeEnabled = false)

    @Test
    fun `http and https go through the proxy by default`() {
        assertTrue(tunnelsThroughProxy(httpOnly, 80))
        assertTrue(tunnelsThroughProxy(httpOnly, 443))
    }

    @Test
    fun `other ports are dialled directly so the device keeps working`() {
        assertFalse(tunnelsThroughProxy(httpOnly, 22))
        assertFalse(tunnelsThroughProxy(httpOnly, 3306))
        assertFalse(tunnelsThroughProxy(httpOnly, 8080))
    }

    @Test
    fun `dropping the http-only restriction sends every port to the proxy`() {
        assertTrue(tunnelsThroughProxy(everything, 22))
        assertTrue(tunnelsThroughProxy(everything, 8080))
    }

    private fun toward(address: String): Boolean = isLoopbackTraffic(
        InetAddress.getByName("10.0.2.15"),
        InetAddress.getByName(address),
    )

    @Test
    fun `localhost destinations are this device talking to itself`() {
        assertTrue(toward("127.0.0.1"))
        assertTrue(toward("127.0.0.53"))
        assertTrue(isLoopbackTraffic(
            InetAddress.getByName("10.0.2.15"),
            InetAddress.getByAddress(ByteArray(15) + 1.toByte()),
        ))
        assertFalse(toward("10.0.2.2"))
        assertFalse(toward("10.255.0.1"))
        assertFalse(toward("203.0.113.7"))
    }

    @Test
    fun `a packet from loopback is left alone too`() {
        // A server answering, or a local proxy, is addressed *from* loopback rather than to it.
        assertTrue(isLoopbackTraffic(InetAddress.getByName("127.0.0.1"), InetAddress.getByName("10.0.2.15")))
    }

    @Test
    fun `turning proxy mode off sends nothing to the proxy`() {
        assertFalse(tunnelsThroughProxy(bypassed, 80))
        assertFalse(tunnelsThroughProxy(bypassed, 443))
        assertFalse(tunnelsThroughProxy(VpnConfig(proxyModeEnabled = false, routeHttpOnly = false), 443))
    }
}
