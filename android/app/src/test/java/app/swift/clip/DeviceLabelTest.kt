package app.swift.clip

import org.junit.Assert.assertEquals
import org.junit.Test

class DeviceLabelTest {
    @Test
    fun customNameBeatsBluetoothSystemAndModel() {
        assertEquals(
            "rai pixel 8",
            ClipSync.chooseLabel("rai pixel 8", "Pixel 8", "Pixel", "Pixel 8"),
        )
    }

    @Test
    fun bluetoothNameBeatsSystemAndModel() {
        assertEquals(
            "rai pixel 8",
            ClipSync.chooseLabel("  ", "rai pixel 8", "Pixel 8", "Pixel 8"),
        )
    }

    @Test
    fun systemNameBeatsModel() {
        assertEquals(
            "Rai's phone",
            ClipSync.chooseLabel(null, null, "Rai's phone", "Pixel 8"),
        )
    }

    @Test
    fun modelIsTheLastResort() {
        assertEquals("Pixel 8", ClipSync.chooseLabel(null, null, null, "Pixel 8"))
    }

    @Test
    fun systemNameBeatsAModelShapedBluetoothName() {
        assertEquals(
            "Rai's Pixel 8",
            ClipSync.chooseLabel(null, "Pixel 8", "Rai's Pixel 8", "Pixel 8"),
        )
    }
}
