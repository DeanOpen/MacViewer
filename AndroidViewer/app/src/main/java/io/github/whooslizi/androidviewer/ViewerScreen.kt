package io.github.whooslizi.androidviewer

import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import kotlin.math.roundToInt

@Composable
fun ViewerScreen(session: RemoteSession) {
    val context = LocalContext.current
    var zoom by remember { mutableFloatStateOf(1f) }
    var pan by remember { mutableStateOf(Offset.Zero) }
    var window by remember { mutableStateOf(IntSize.Zero) }
    var keyboard by rememberSaveable { mutableStateOf(false) }
    var showPointer by rememberSaveable { mutableStateOf(true) }
    var trackpad by rememberSaveable { mutableStateOf(false) }
    val pickFile = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri?.let(session::sendFile)
    }
    val view = session.viewRect()
    val transform = view?.takeIf { window.width > 0 && window.height > 0 }
        ?.let { ViewTransform(window.width.toFloat(), window.height.toFloat(), it, zoom, pan) }
    // The gesture loop outlives recompositions; it must read the latest transform.
    val currentTransform by rememberUpdatedState(transform)
    val currentTrackpad by rememberUpdatedState(trackpad)
    LaunchedEffect(session.monitor) {
        zoom = 1f
        pan = Offset.Zero
    }

    Column(Modifier.fillMaxSize().background(Color.Black).safeDrawingPadding().imePadding()) {
        Row(
            Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surface).padding(start = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                if (session.viewOnly) stringResource(R.string.view_only) else session.status,
                Modifier.weight(1f), maxLines = 1, style = MaterialTheme.typography.bodyMedium,
            )
            TextButton(onClick = { keyboard = !keyboard }) { Text(stringResource(if (keyboard) R.string.hide_keys else R.string.keyboard)) }
            TextButton(onClick = { zoom = 1f; pan = Offset.Zero }) { Text(stringResource(R.string.fit)) }
            TextButton(onClick = { session.disconnect() }) { Text(stringResource(R.string.disconnect)) }
            SessionMenu(
                session, showPointer, onShowPointer = { showPointer = it },
                trackpad = trackpad, onTrackpad = { trackpad = it },
                onScreenshot = {
                    val b = session.bitmap
                    if (b != null && view != null) saveScreenshot(context, b, view) {
                        Toast.makeText(context, it, Toast.LENGTH_SHORT).show()
                    }
                },
                onSendFile = { pickFile.launch(arrayOf("*/*")) },
            )
        }
        TransfersBar(session)

        Box(
            Modifier.weight(1f).fillMaxWidth().onSizeChanged { window = it }.pointerInput(session) {
                remoteTouchGestures(
                    session,
                    transform = { currentTransform },
                    onPinch = { factor, centroid, move ->
                        currentTransform?.pinched(factor, centroid, move)?.let { zoom = it.zoom; pan = it.pan }
                    },
                    isZoomed = { zoom > 1f },
                    trackpad = { currentTrackpad },
                )
            },
        ) {
            Canvas(Modifier.fillMaxSize()) {
                session.frameVersion // read so every frame redraws
                val b = session.bitmap ?: return@Canvas
                val t = transform ?: return@Canvas
                val v = t.view
                drawImage(
                    b.asImageBitmap(),
                    srcOffset = IntOffset(v.left, v.top), srcSize = IntSize(v.width, v.height),
                    dstOffset = IntOffset(t.topLeft.x.roundToInt(), t.topLeft.y.roundToInt()),
                    dstSize = IntSize((v.width * t.scale).roundToInt(), (v.height * t.scale).roundToInt()),
                    filterQuality = if (t.scale < 1f) FilterQuality.Medium else FilterQuality.None,
                )
                val p = session.pointer
                if (showPointer && p != null) {
                    // At least actual size, so the pointer stays visible on a small phone screen.
                    val s = maxOf(t.scale, 1f)
                    val tip = t.toWindow(p.x.toFloat(), p.y.toFloat())
                    drawImage(
                        p.bitmap.asImageBitmap(),
                        dstOffset = IntOffset((tip.x - p.hotX * s).roundToInt(), (tip.y - p.hotY * s).roundToInt()),
                        dstSize = IntSize((p.bitmap.width * s).roundToInt(), (p.bitmap.height * s).roundToInt()),
                    )
                }
            }
            if (session.bitmap == null) {
                Text(session.status, Modifier.padding(24.dp), color = Color.White)
            }
        }

        if (session.chatOpen) ChatPanel(session)
        if (keyboard) KeyboardBar(session)
    }
    FileOfferDialog(session)
}
