package com.proxymaxx.vpn.vpn

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

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

    @Test
    fun `turning proxy mode off sends nothing to the proxy`() {
        assertFalse(tunnelsThroughProxy(bypassed, 80))
        assertFalse(tunnelsThroughProxy(bypassed, 443))
        assertFalse(tunnelsThroughProxy(VpnConfig(proxyModeEnabled = false, routeHttpOnly = false), 443))
    }
}
