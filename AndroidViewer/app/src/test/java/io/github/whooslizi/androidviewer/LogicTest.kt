package io.github.whooslizi.androidviewer

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntRect
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class LogicTest {
    @Test
    fun parsesEvents() {
        assertEquals(
            SessionEvent.Connected(3840, 1080, -1920, 0, listOf(Monitor(-1920, 0, 0, 1080), Monitor(0, 0, 1920, 1080))),
            SessionEvent.parse("connected\t3840\t1080\t-1920\t0\t-1920,0,0,1080;0,0,1920,1080"),
        )
        assertEquals(SessionEvent.Connected(800, 600, 0, 0, emptyList()), SessionEvent.parse("connected\t800\t600\t0\t0\t"))
        assertEquals(SessionEvent.Cursor(10, -5, "123"), SessionEvent.parse("cursor\t10\t-5\t123"))
        assertEquals(SessionEvent.Cursor(null, null, null), SessionEvent.parse("cursor\t-\t-\t-"))
        assertEquals(SessionEvent.Closed(""), SessionEvent.parse("closed\t"))
        assertEquals(SessionEvent.Status("a b"), SessionEvent.parse("status\ta b"))
        assertEquals(SessionEvent.Chat("a\tb"), SessionEvent.parse("chat\ta\tb"))
        assertEquals(SessionEvent.Clipboard(""), SessionEvent.parse("clipboard\t"))
        assertEquals(SessionEvent.FileOffer("T1", 2048, "report final.pdf"), SessionEvent.parse("fileoffer\tT1\t2048\treport final.pdf"))
        assertEquals(SessionEvent.FileProgress("T1", 1024), SessionEvent.parse("fileprogress\tT1\t1024"))
        assertEquals(SessionEvent.FileFailed("T1", "disk full"), SessionEvent.parse("filefailed\tT1\tdisk full"))
        assertEquals(SessionEvent.Audio, SessionEvent.parse("audio"))
        assertNull(SessionEvent.parse("unknown\tx"))
    }

    @Test
    fun keepsOfferedNamesInsideTheFolder() {
        assertEquals("a.txt", safeFileName("a.txt"))
        assertEquals("evil.txt", safeFileName("../../evil.txt"))
        assertEquals("b.txt", safeFileName("C:\\Users\\b.txt"))
        assertEquals("file", safeFileName(".."))
        assertEquals("file", safeFileName("dir/"))
    }

    @Test
    fun trackpadMovesByTravelAndStaysOnScreen() {
        val view = IntRect(0, 0, 1000, 500)
        assertEquals(Offset(120f, 100f), movedPointer(Offset(100f, 100f), Offset(10f, 0f), 0.5f, view))
        assertEquals(Offset(999f, 0f), movedPointer(Offset(990f, 10f), Offset(100f, -100f), 1f, view))
    }

    @Test
    fun fitsCentresAndMapsTouches() {
        // 2000x1000 canvas in a 1000x1000 window: scale 0.5, 250 px bars above and below.
        val t = ViewTransform(1000f, 1000f, IntRect(0, 0, 2000, 1000))
        assertEquals(0.5f, t.scale)
        assertEquals(Offset(0f, 250f), t.topLeft)
        assertEquals(IntOffset(1000, 500), t.toCanvas(Offset(500f, 500f)))
        assertEquals(IntOffset(0, 0), t.toCanvas(Offset(-50f, 0f))) // clamped
        assertEquals(Offset(500f, 500f), t.toWindow(1000f, 500f))
    }

    @Test
    fun monitorViewMapsIntoItsRegion() {
        val t = ViewTransform(1920f, 1080f, IntRect(1920, 0, 3840, 1080))
        assertEquals(IntOffset(1920, 0), t.toCanvas(Offset(0f, 0f)))
        assertEquals(IntOffset(3839, 1079), t.toCanvas(Offset(5000f, 5000f)))
    }

    @Test
    fun pinchKeepsThePointUnderTheFingers() {
        val t = ViewTransform(1000f, 1000f, IntRect(0, 0, 1000, 1000))
        val finger = Offset(200f, 300f)
        val zoomed = t.pinched(2f, finger, Offset.Zero)
        assertEquals(2f, zoomed.zoom)
        assertEquals(t.toCanvas(finger), zoomed.toCanvas(finger))
        // Pinching back out returns to the fitted, centred view.
        assertEquals(t, zoomed.pinched(0.1f, finger, Offset.Zero))
    }

    @Test
    fun panStaysWithinTheScreen() {
        val zoomed = ViewTransform(1000f, 1000f, IntRect(0, 0, 1000, 1000), zoom = 2f)
        // Content is 2000 px wide: at most 500 px of pan either way keeps the window covered.
        assertEquals(Offset(500f, -500f), zoomed.pinched(1f, Offset(500f, 500f), Offset(9000f, -9000f)).pan)
        // A screen narrower than the window stays centred horizontally.
        val wide = ViewTransform(1000f, 2000f, IntRect(0, 0, 1000, 1000))
        assertEquals(0f, wide.pinched(1f, Offset.Zero, Offset(300f, 0f)).pan.x)
    }

    @Test
    fun twoFingersPickPinchOrScrollOnce() {
        val slop = 10f
        assertNull(twoFingerMode(1.02f, Offset(0f, 5f), zoomed = false, slop))
        assertEquals(TwoFingerMode.Pinch, twoFingerMode(1.1f, Offset.Zero, zoomed = false, slop))
        assertEquals(TwoFingerMode.Scroll, twoFingerMode(1.01f, Offset(0f, 30f), zoomed = false, slop))
        assertEquals(TwoFingerMode.Pinch, twoFingerMode(1.01f, Offset(0f, 30f), zoomed = true, slop))
    }

    @Test
    fun keyboardEditsBecomeBackspacesAndText() {
        assertEquals(TextEdit(0, "a"), TextEdit.between(" ", " a"))
        assertEquals(TextEdit(1, ""), TextEdit.between(" ", ""))
        assertEquals(TextEdit(1, "â"), TextEdit.between(" a", " â")) // IME rewrite (Telex aa → â)
        assertEquals("123 456 789", groupId("123456789"))
        assertEquals("1 234", groupId("1234"))
    }
}
