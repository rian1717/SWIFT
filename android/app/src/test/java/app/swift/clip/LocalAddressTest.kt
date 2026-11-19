package app.swift.clip

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LocalAddressTest {
    private fun at(name: String, host: String) = AddressRules.Candidate(name, host, 24)

    @Test
    fun mobileDataAloneGivesNoAddress() {
        // What the iPhone was sent: a mobile-data address nobody nearby can reach.
        val found = listOf(at("rmnet_data0", "10.155.236.253"))
        assertNull(AddressRules.pick(found, wifi = emptySet(), away = setOf("rmnet_data0")))
        assertNull(AddressRules.pick(found, wifi = emptySet(), away = emptySet()))
    }

    @Test
    fun wifiWinsOverMobileDataWhicheverComesFirst() {
        val found = listOf(at("rmnet_data0", "10.155.236.253"), at("wlan0", "192.168.0.138"))
        assertEquals("192.168.0.138", AddressRules.pick(found, setOf("wlan0"), setOf("rmnet_data0"))?.host)
        // Even if Android could not say which is which.
        assertEquals("192.168.0.138", AddressRules.pick(found, emptySet(), emptySet())?.host)
    }

    @Test
    fun aWifiNetworkOnTenDotIsFine() {
        val found = listOf(at("ccmni1", "10.20.30.40"), at("wlan0", "10.0.0.12"))
        assertEquals("10.0.0.12", AddressRules.pick(found, setOf("wlan0"), setOf("ccmni1"))?.host)
    }

    @Test
    fun thisPhonesHotspotIsUsedWhenItHasNoWifi() {
        val found = listOf(at("rmnet_data1", "10.71.4.2"), at("swlan0", "192.168.43.1"))
        assertEquals("192.168.43.1", AddressRules.pick(found, emptySet(), setOf("rmnet_data1"))?.host)
        val pixel = listOf(at("rmnet1", "10.71.4.2"), at("ap0", "192.168.80.1"))
        assertEquals("192.168.80.1", AddressRules.pick(pixel, emptySet(), setOf("rmnet1"))?.host)
    }

    @Test
    fun aVpnIsIgnored() {
        val found = listOf(at("tun0", "10.8.0.2"), at("wlan0", "192.168.1.20"))
        assertEquals("192.168.1.20", AddressRules.pick(found, setOf("wlan0"), setOf("tun0"))?.host)
        assertNull(AddressRules.pick(listOf(at("tun0", "10.8.0.2")), emptySet(), setOf("tun0")))
    }

    @Test
    fun anUnknownNameCountsWhenAndroidSaysItIsWifi() {
        val found = listOf(at("wifi0", "192.168.5.9"))
        assertEquals("192.168.5.9", AddressRules.pick(found, setOf("wifi0"), emptySet())?.host)
        assertNull(AddressRules.pick(found, emptySet(), emptySet()))
    }

    @Test
    fun onlyPrivateAddresses() {
        assertTrue(AddressRules.isPrivate("192.168.0.138"))
        assertTrue(AddressRules.isPrivate("172.20.1.1"))
        assertFalse(AddressRules.isPrivate("172.32.1.1"))
        assertFalse(AddressRules.isPrivate("100.64.1.1"))
        assertFalse(AddressRules.isPrivate("8.8.8.8"))
        assertFalse(AddressRules.isPrivate("192.168.1"))
    }
}
