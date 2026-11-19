package app.swift.clip

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import java.net.Inet4Address
import java.net.NetworkInterface

/**
 * This phone's address on the Wi-Fi in the room: the one an iPhone or a Mac nearby can reach.
 *
 * Mobile data and VPN addresses are often private too (10.x), so a private address
 * alone is not enough. Android says which interfaces are Wi-Fi, mobile data or a VPN.
 */
object LocalNetwork {
    data class Address(val host: String, val prefix: Int, val bytes: ByteArray)

    fun address(context: Context): Address? {
        val wifi = HashSet<String>()
        val away = HashSet<String>()
        try {
            val manager = context.applicationContext.getSystemService(ConnectivityManager::class.java)
            @Suppress("DEPRECATION")
            val networks = manager?.allNetworks ?: emptyArray()
            for (network in networks) {
                val caps = manager?.getNetworkCapabilities(network) ?: continue
                val name = manager.getLinkProperties(network)?.interfaceName ?: continue
                val local = !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
                    (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                        caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET))
                if (local) wifi.add(name) else away.add(name)
            }
        } catch (_: Exception) {
        }
        val found = ArrayList<AddressRules.Candidate>()
        try {
            val interfaces = NetworkInterface.getNetworkInterfaces()
            if (interfaces != null) {
                for (nic in interfaces) {
                    if (!nic.isUp || nic.isLoopback) continue
                    for (entry in nic.interfaceAddresses) {
                        val ip = entry.address as? Inet4Address ?: continue
                        val host = ip.hostAddress ?: continue
                        found.add(AddressRules.Candidate(nic.name, host, entry.networkPrefixLength.toInt()))
                    }
                }
            }
        } catch (_: Exception) {
        }
        val best = AddressRules.pick(found, wifi, away) ?: return null
        val bytes = best.host.split('.').map { it.toInt().toByte() }.toByteArray()
        return Address(best.host, best.prefix, bytes)
    }
}

/** Kept apart from Android so it can be tested on the computer. */
internal object AddressRules {
    data class Candidate(val name: String, val host: String, val prefix: Int)

    /** Interface names phones use for mobile data, VPNs and Wi-Fi Direct. Nobody nearby reaches these. */
    private val unreachable = Regex(
        "^(rmnet|rev_rmnet|v4-|clat|ccmni|ccemni|seth|pdp|ppp|tun|ipsec|wwan|qmi|dummy|p2p|aware|nan|ifb|gre|sit|ip6)",
        RegexOption.IGNORE_CASE,
    )

    /** Interfaces a phone uses when it is the hotspot, or shares its network by cable or Bluetooth. */
    private val hotspot = Regex("^(ap|swlan|softap|wlan|rndis|usb|ncm|bt-pan|eth)", RegexOption.IGNORE_CASE)

    /**
     * Picks the address to give out. A Wi-Fi network Android knows comes first, then
     * this phone's own hotspot. Mobile data and VPN interfaces are never used.
     */
    fun pick(found: List<Candidate>, wifi: Set<String>, away: Set<String>): Candidate? {
        val usable = found.filter { isPrivate(it.host) && it.name !in away && !unreachable.containsMatchIn(it.name) }
        return usable.firstOrNull { it.name in wifi && it.name.startsWith("wlan") }
            ?: usable.firstOrNull { it.name in wifi }
            ?: usable.firstOrNull { hotspot.containsMatchIn(it.name) }
    }

    fun isPrivate(host: String): Boolean {
        val parts = host.split('.').map { it.toIntOrNull() ?: return false }
        if (parts.size != 4 || parts.any { it !in 0..255 }) return false
        return parts[0] == 10 ||
            (parts[0] == 192 && parts[1] == 168) ||
            (parts[0] == 172 && parts[1] in 16..31)
    }
}
