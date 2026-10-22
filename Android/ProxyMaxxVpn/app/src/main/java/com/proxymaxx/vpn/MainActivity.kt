package com.proxymaxx.vpn

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.Security
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.proxymaxx.vpn.theme.PrimaryPurple
import com.proxymaxx.vpn.theme.ProxyMaxxVPNTheme
import com.proxymaxx.vpn.vpn.ProxyMaxxVpnService
import com.proxymaxx.vpn.vpn.VpnConfig
import com.proxymaxx.vpn.vpn.VpnConfigStore

class MainActivity : ComponentActivity() {

    private var pendingConfig: VpnConfig? = null

    private val consent = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        val config = pendingConfig ?: return@registerForActivityResult
        pendingConfig = null
        if (result.resultCode == Activity.RESULT_OK) startTunnel(config)
    }

    private val notifications = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { requestConsent() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val launchConfig = resolveConfig(intent)
        val autoStart = intent?.getBooleanExtra(VpnConfig.EXTRA_AUTO_START, false) == true
        setContent {
            ProxyMaxxVPNTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background,
                ) {
                    VpnScreen(
                        initialConfig = launchConfig,
                        onConnect = { config -> requestConnect(config) },
                        onDisconnect = { stopTunnel() },
                    )
                }
            }
        }
        if (autoStart) {
            window.decorView.post { if (!ProxyMaxxVpnService.isConnected.value) requestConnect(launchConfig) }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (!intent.getBooleanExtra(VpnConfig.EXTRA_AUTO_START, false)) return
        val config = resolveConfig(intent)
        window.decorView.post { if (!ProxyMaxxVpnService.isConnected.value) requestConnect(config) }
    }

    /**
     * Settings carried by the intent win; anything else falls back to the last settings the
     * tunnel ran with, so the tile and the app share one configuration.
     */
    private fun resolveConfig(intent: Intent?): VpnConfig =
        if (VpnConfig.hasConfigExtras(intent)) VpnConfig.fromIntent(intent) else VpnConfigStore.load(this)

    private fun requestConnect(config: VpnConfig) {
        pendingConfig = config
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            notifications.launch(Manifest.permission.POST_NOTIFICATIONS)
        } else {
            requestConsent()
        }
    }

    private fun requestConsent() {
        val config = pendingConfig ?: return
        val prompt = VpnService.prepare(this)
        if (prompt == null) {
            pendingConfig = null
            startTunnel(config)
        } else {
            consent.launch(prompt)
        }
    }

    private fun startTunnel(config: VpnConfig) {
        VpnConfigStore.save(this, config)
        startForegroundService(VpnConfig.startIntent(this, config))
    }

    private fun stopTunnel() {
        startService(VpnConfig.stopIntent(this))
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun VpnScreen(
    initialConfig: VpnConfig,
    onConnect: (VpnConfig) -> Unit,
    onDisconnect: () -> Unit,
) {
    val connected by ProxyMaxxVpnService.isConnected.collectAsStateWithLifecycle()

    var host by rememberSaveable { mutableStateOf(initialConfig.proxyHost) }
    var socksPort by rememberSaveable { mutableStateOf(initialConfig.socksPort.toString()) }
    var httpPort by rememberSaveable { mutableStateOf(initialConfig.httpPort.toString()) }

    var showSettingsSheet by rememberSaveable { mutableStateOf(false) }
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    val socks = socksPort.toIntOrNull()
    val http = httpPort.toIntOrNull()
    val valid = host.isNotBlank() && socks != null && socks in 1..65535 && http != null && http in 1..65535

    // Smooth color and elevation animations
    val heroCardColor by animateColorAsState(
        targetValue = if (connected) PrimaryPurple else MaterialTheme.colorScheme.surface,
        animationSpec = tween(durationMillis = 500),
        label = "heroCardColor",
    )
    val heroCardElevation by animateDpAsState(
        targetValue = if (connected) 8.dp else 1.dp,
        animationSpec = tween(durationMillis = 500),
        label = "heroCardElevation",
    )

    Column(
        modifier = Modifier
            .fillMaxSize()
            .safeDrawingPadding()
            .verticalScroll(rememberScrollState())
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        // 1. Top Bar: ProxyMaxx + Status Badge
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = buildAnnotatedString {
                    withStyle(SpanStyle(color = MaterialTheme.colorScheme.onBackground, fontWeight = FontWeight.Bold)) {
                        append("Proxy")
                    }
                    withStyle(SpanStyle(color = PrimaryPurple, fontWeight = FontWeight.Bold)) {
                        append("Maxx")
                    }
                },
                style = MaterialTheme.typography.titleLarge,
                fontSize = 24.sp,
            )

            // Status Badge Pill
            Surface(
                shape = RoundedCornerShape(20.dp),
                color = if (connected) PrimaryPurple.copy(alpha = 0.15f) else MaterialTheme.colorScheme.surfaceVariant,
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Box(
                        modifier = Modifier
                            .size(8.dp)
                            .clip(CircleShape)
                            .background(if (connected) PrimaryPurple else Color.Gray),
                    )
                    Text(
                        text = if (connected) "Connected" else "Disconnected",
                        style = MaterialTheme.typography.labelMedium,
                        fontWeight = FontWeight.Medium,
                        color = if (connected) PrimaryPurple else MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }

        // 2. Session Hero Card with smooth background and elevation animation
        Card(
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(
                containerColor = heroCardColor,
            ),
            shape = RoundedCornerShape(24.dp),
            elevation = CardDefaults.cardElevation(defaultElevation = heroCardElevation),
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(24.dp),
                verticalArrangement = Arrangement.spacedBy(20.dp),
            ) {
                Text(
                    text = "Session",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = if (connected) Color.White.copy(alpha = 0.9f) else MaterialTheme.colorScheme.onSurface,
                )

                // 3 Status Icons Row (Device, VPN, Proxy)
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    HeroStatusBadge(
                        icon = Icons.Default.PhoneAndroid,
                        label = "Device",
                        connected = connected,
                    )
                    HeroStatusBadge(
                        icon = Icons.Default.Security,
                        label = "VPN",
                        connected = connected,
                    )
                    HeroStatusBadge(
                        icon = Icons.Default.Dns,
                        label = "Proxy",
                        connected = connected,
                    )
                }

                // Connect / Disconnect Button
                Button(
                    onClick = {
                        if (connected) {
                            onDisconnect()
                        } else if (valid) {
                            onConnect(
                                VpnConfig(
                                    proxyHost = host.trim(),
                                    socksPort = socks,
                                    httpPort = http,
                                    proxyModeEnabled = true,
                                    routeHttpOnly = true,
                                ),
                            )
                        }
                    },
                    enabled = connected || valid,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(52.dp),
                    shape = RoundedCornerShape(16.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = if (connected) Color.White else PrimaryPurple,
                        contentColor = if (connected) PrimaryPurple else Color.White,
                    ),
                ) {
                    Text(
                        text = if (connected) "Disconnect" else "Connect",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                    )
                }
            }
        }

        // 3. Proxy Summary Card
        Card(
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
            shape = RoundedCornerShape(20.dp),
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(20.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = "Proxy",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                    )
                    Spacer(Modifier.height(4.dp))
                    Text(
                        text = "$host · HTTP $httpPort",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }

                if (connected) {
                    Surface(
                        shape = RoundedCornerShape(12.dp),
                        color = MaterialTheme.colorScheme.surfaceVariant,
                    ) {
                        Text(
                            text = "Locked",
                            modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                } else {
                    OutlinedButton(
                        onClick = { showSettingsSheet = true },
                        shape = RoundedCornerShape(12.dp),
                    ) {
                        Text("Edit")
                    }
                }
            }
        }

        // Footer note matching design with animated fade transition
        AnimatedVisibility(
            visible = true,
            enter = fadeIn(animationSpec = tween(400)),
            exit = fadeOut(animationSpec = tween(400)),
        ) {
            Text(
                text = if (connected)
                    "Disconnect to change proxy settings."
                else
                    "Some frameworks ignore the system proxy. ProxyMaxx routes all device traffic so nothing is missed.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 4.dp),
            )
        }
    }

    // 4. Proxy Settings Bottom Sheet (Screenshot 3)
    if (showSettingsSheet) {
        ModalBottomSheet(
            onDismissRequest = { showSettingsSheet = false },
            sheetState = sheetState,
            containerColor = MaterialTheme.colorScheme.surface,
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(24.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Text(
                    text = "Proxy settings",
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.Bold,
                )

                OutlinedTextField(
                    value = host,
                    onValueChange = { host = it },
                    label = { Text("Host") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(12.dp),
                )

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    OutlinedTextField(
                        value = socksPort,
                        onValueChange = { socksPort = it.filter(Char::isDigit) },
                        label = { Text("SOCKS5 port") },
                        singleLine = true,
                        modifier = Modifier.weight(1f),
                        shape = RoundedCornerShape(12.dp),
                    )
                    OutlinedTextField(
                        value = httpPort,
                        onValueChange = { httpPort = it.filter(Char::isDigit) },
                        label = { Text("HTTP port") },
                        singleLine = true,
                        modifier = Modifier.weight(1f),
                        shape = RoundedCornerShape(12.dp),
                    )
                }

                Text(
                    text = "10.0.2.2 is the emulator's alias for your host machine.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )

                Spacer(Modifier.height(8.dp))

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    OutlinedButton(
                        onClick = { /* Test connection action */ },
                        modifier = Modifier
                            .weight(1f)
                            .height(50.dp),
                        shape = RoundedCornerShape(14.dp),
                    ) {
                        Text("Test")
                    }

                    Button(
                        onClick = { showSettingsSheet = false },
                        modifier = Modifier
                            .weight(1f)
                            .height(50.dp),
                        shape = RoundedCornerShape(14.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = PrimaryPurple),
                    ) {
                        Text("Save")
                    }
                }

                Spacer(Modifier.height(24.dp))
            }
        }
    }
}

@Composable
private fun HeroStatusBadge(
    icon: ImageVector,
    label: String,
    connected: Boolean,
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Surface(
            shape = RoundedCornerShape(16.dp),
            color = if (connected) Color.White.copy(alpha = 0.2f) else MaterialTheme.colorScheme.surfaceVariant,
            modifier = Modifier.size(56.dp),
        ) {
            Box(contentAlignment = Alignment.Center) {
                Icon(
                    imageVector = icon,
                    contentDescription = label,
                    tint = if (connected) Color.White else PrimaryPurple,
                    modifier = Modifier.size(24.dp),
                )
            }
        }
        Text(
            text = label,
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = FontWeight.Medium,
            color = if (connected) Color.White.copy(alpha = 0.9f) else MaterialTheme.colorScheme.onSurface,
        )
    }
}
