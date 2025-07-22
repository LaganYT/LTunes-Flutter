package com.LTunes

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Bundle
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.ryanheise.audioservice.AudioServiceActivity

class MainActivity : AudioServiceActivity() {
    private val CHANNEL = "bluetooth_events"
    private var bluetoothReceiver: BroadcastReceiver? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).also { channel ->
            // Register Bluetooth receiver
            bluetoothReceiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context?, intent: Intent?) {
                    when (intent?.action) {
                        BluetoothDevice.ACTION_ACL_CONNECTED -> {
                            channel.invokeMethod("bluetooth_connected", null)
                        }
                        BluetoothDevice.ACTION_ACL_DISCONNECTED -> {
                            channel.invokeMethod("bluetooth_disconnected", null)
                        }
                    }
                }
            }
            val filter = IntentFilter().apply {
                addAction(BluetoothDevice.ACTION_ACL_CONNECTED)
                addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED)
            }
            registerReceiver(bluetoothReceiver, filter)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        if (bluetoothReceiver != null) {
            unregisterReceiver(bluetoothReceiver)
            bluetoothReceiver = null
        }
    }
}
