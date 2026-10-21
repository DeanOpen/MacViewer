package io.github.whooslizi.androidviewer

import android.text.format.Formatter
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp

@Composable
fun ChatPanel(session: RemoteSession) {
    var draft by rememberSaveable { mutableStateOf("") }
    val list = rememberLazyListState()
    LaunchedEffect(session.chat.size) {
        if (session.chat.isNotEmpty()) list.animateScrollToItem(session.chat.lastIndex)
    }
    Column(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surface).padding(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.chat), Modifier.weight(1f), style = MaterialTheme.typography.titleSmall)
            if (session.partnerTyping) {
                Text(stringResource(R.string.partner_typing), style = MaterialTheme.typography.bodySmall)
            }
            TextButton(onClick = { session.showChat(false) }) { Text(stringResource(R.string.close)) }
        }
        LazyColumn(Modifier.fillMaxWidth().heightIn(max = 180.dp), state = list,
                   verticalArrangement = Arrangement.spacedBy(4.dp)) {
            items(session.chat) { line ->
                Row(Modifier.fillMaxWidth(), horizontalArrangement = if (line.mine) Arrangement.End else Arrangement.Start) {
                    Text(
                        line.text,
                        Modifier.background(
                            if (line.mine) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceVariant,
                            RoundedCornerShape(12.dp),
                        ).padding(horizontal = 10.dp, vertical = 6.dp),
                    )
                }
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(
                draft, { draft = it }, Modifier.weight(1f),
                placeholder = { Text(stringResource(R.string.chat_message)) }, maxLines = 3,
            )
            TextButton(
                onClick = { session.sendChat(draft.trim()); draft = "" },
                enabled = draft.isNotBlank(),
            ) { Text(stringResource(R.string.send)) }
        }
    }
}

@Composable
fun TransfersBar(session: RemoteSession) {
    for (t in session.transfers) {
        Row(
            Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surface).padding(start = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text((if (t.incoming) "↓ " else "↑ ") + t.name, Modifier.weight(1f), maxLines = 1,
                 style = MaterialTheme.typography.bodySmall)
            LinearProgressIndicator(
                progress = { if (t.size > 0) (t.bytes.toFloat() / t.size).coerceIn(0f, 1f) else 0f },
                Modifier.weight(1f),
            )
            val cancel = stringResource(R.string.cancel_transfer, t.name)
            TextButton(onClick = { session.cancel(t) }, Modifier.semantics { contentDescription = cancel }) {
                Text("✕", Modifier.clearAndSetSemantics {})
            }
        }
    }
}

@Composable
fun FileOfferDialog(session: RemoteSession) {
    val offer = session.offers.firstOrNull() ?: return
    val size = Formatter.formatShortFileSize(LocalContext.current, offer.size)
    AlertDialog(
        onDismissRequest = {},
        title = { Text(stringResource(R.string.receive_file_title)) },
        text = { Text(stringResource(R.string.receive_file_message, offer.name, size)) },
        confirmButton = { TextButton(onClick = { session.accept(offer) }) { Text(stringResource(R.string.receive)) } },
        dismissButton = { TextButton(onClick = { session.decline(offer) }) { Text(stringResource(R.string.decline)) } },
    )
}
